// Discord Interactions Webhook を処理する Lambda（Function URL 経由 / nodejs24.x / ESM）
//
// 役割:
//   - Lambda Function URL に登録された Discord Interactions Endpoint としてリクエストを受ける
//   - Ed25519 署名検証（不正は 401）
//   - type=1(PING) には {type:1} を返す
//   - type=2(APPLICATION_COMMAND) を data.name で分岐し以下を処理する
//       - `/start`   ... 停止中なら ASG の desired を 0->1 にして起動
//       - `/restart` ... 稼働中なら現インスタンスを停止して最新 MOD 構成で作り直し、
//                          停止中なら desired=1 で起動（MOD更新を S3 から取り込み直す用途）
//
// 環境変数:
//   ASG_NAME                 ... 起動対象の Auto Scaling Group 名（minecraft-asg-prd）
//   DISCORD_PUBLIC_KEY_SSM   ... Discord アプリ公開鍵を保持する SSM パラメータ名
//
// AWS SDK v3 / Node 標準 crypto は nodejs24.x ランタイムに同梱されるため依存追加は不要。

import crypto from "node:crypto";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";
import {
  AutoScalingClient,
  DescribeAutoScalingGroupsCommand,
  SetDesiredCapacityCommand,
  TerminateInstanceInAutoScalingGroupCommand,
} from "@aws-sdk/client-auto-scaling";

// Lambda 実行環境では AWS_REGION が自動設定される。ローカルでの静的検証等に備えて
// フォールバックのみ残し、CFn が渡す REGION env には依存しない。
const REGION = process.env.AWS_REGION ?? "ap-northeast-1";

const ssmClient = new SSMClient({ region: REGION });
const autoScalingClient = new AutoScalingClient({ region: REGION });

// Discord Interaction の type / response type
const INTERACTION_TYPE_PING = 1;
const INTERACTION_TYPE_APPLICATION_COMMAND = 2;
const RESPONSE_TYPE_PONG = 1;
const RESPONSE_TYPE_CHANNEL_MESSAGE = 4;

// SSM から取得した公開鍵をコールドスタート時に1回だけ生成しキャッシュする
let cachedPublicKey = null;

/**
 * Discord アプリの公開鍵(hex 32byte)を SSM から取得し、Ed25519 検証用の KeyObject に変換する。
 * 取得した鍵はモジュールスコープにキャッシュし、ウォームスタートでは再取得しない。
 *
 * @returns {Promise<crypto.KeyObject>} Ed25519 公開鍵オブジェクト
 */
async function getPublicKey() {
  if (cachedPublicKey) {
    return cachedPublicKey;
  }

  const parameterName = process.env.DISCORD_PUBLIC_KEY_SSM;
  const { Parameter } = await ssmClient.send(
    new GetParameterCommand({ Name: parameterName, WithDecryption: true })
  );

  // raw な Ed25519 公開鍵(32byte) を SPKI DER ヘッダで包んで KeyObject 化する
  const rawKey = Buffer.from(Parameter.Value.trim(), "hex");
  const spkiDer = Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    rawKey,
  ]);
  cachedPublicKey = crypto.createPublicKey({
    key: spkiDer,
    format: "der",
    type: "spki",
  });

  return cachedPublicKey;
}

/**
 * Discord の Ed25519 署名を検証する。
 * 署名対象は「timestamp + rawBody」、署名は x-signature-ed25519(hex)。
 *
 * @param {string} rawBody 生のリクエストボディ
 * @param {string} signature x-signature-ed25519 ヘッダ値(hex)
 * @param {string} timestamp x-signature-timestamp ヘッダ値
 * @returns {Promise<boolean>} 検証成功なら true
 */
async function verifySignature(rawBody, signature, timestamp) {
  if (!signature || !timestamp) {
    return false;
  }

  return crypto.verify(
    null,
    Buffer.from(timestamp + rawBody),
    await getPublicKey(),
    Buffer.from(signature, "hex")
  );
}

/**
 * JSON ボディを持つ Function URL レスポンスを生成する。
 *
 * @param {number} statusCode HTTP ステータスコード
 * @param {object} body レスポンスボディ
 * @returns {object} Function URL 形式のレスポンス
 */
function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

// 稼働中とみなす ASG ライフサイクル状態。Terminating 系や落ちかけのインスタンスを
// 「稼働中」と誤判定しないよう、InService と Pending（起動途中）のみを対象にする。
const RUNNING_LIFECYCLE_STATES = new Set(["Pending", "InService"]);

/**
 * ASG の稼働中（InService / Pending）インスタンスの InstanceId 一覧を返す。
 * 落ちかけ（Terminating 系）のインスタンスは稼働中とみなさない。
 *
 * @param {object} group DescribeAutoScalingGroups で得た1グループ
 * @returns {string[]} 稼働中インスタンスの InstanceId 配列
 */
function runningInstanceIds(group) {
  return (group.Instances ?? [])
    .filter((instance) => RUNNING_LIFECYCLE_STATES.has(instance.LifecycleState))
    .map((instance) => instance.InstanceId);
}

/**
 * ASG が「停止中（desired=0 かつ稼働インスタンス無し）」かを判定する。
 *
 * @param {object} group DescribeAutoScalingGroups で得た1グループ
 * @returns {boolean} 停止中なら true
 */
function isStopped(group) {
  return group.DesiredCapacity === 0 && runningInstanceIds(group).length === 0;
}

/**
 * env で指定された ASG の現在状態を取得する。
 *
 * @returns {Promise<object|null>} 対象 ASG。存在しなければ null
 */
async function describeTargetGroup() {
  const { AutoScalingGroups } = await autoScalingClient.send(
    new DescribeAutoScalingGroupsCommand({
      AutoScalingGroupNames: [process.env.ASG_NAME],
    })
  );
  return AutoScalingGroups?.[0] ?? null;
}

/**
 * ASG 構成が見つからなかった場合の Discord 応答を返す。
 *
 * @returns {object} type=4 レスポンス
 */
function groupNotFoundResponse() {
  return jsonResponse(200, {
    type: RESPONSE_TYPE_CHANNEL_MESSAGE,
    data: { content: "⚠️ サーバー構成が見つかりませんでした。管理者に連絡してください。" },
  });
}

/**
 * desired=1 を設定して ASG にインスタンスを起動させる。
 *
 * @returns {Promise<void>}
 */
async function startDesiredCapacity() {
  await autoScalingClient.send(
    new SetDesiredCapacityCommand({
      AutoScalingGroupName: process.env.ASG_NAME,
      DesiredCapacity: 1,
      HonorCooldown: false,
    })
  );
}

/**
 * `/start` コマンドを処理する。停止中なら desired=1 にして起動を開始する。
 *
 * @returns {Promise<object>} Discord へ返す type=4 レスポンス
 */
async function handleStartCommand() {
  const group = await describeTargetGroup();
  if (!group) {
    return groupNotFoundResponse();
  }

  if (!isStopped(group)) {
    return jsonResponse(200, {
      type: RESPONSE_TYPE_CHANNEL_MESSAGE,
      data: { content: "🟡 既に起動中です（または起動済み）。" },
    });
  }

  await startDesiredCapacity();

  return jsonResponse(200, {
    type: RESPONSE_TYPE_CHANNEL_MESSAGE,
    data: {
      content:
        "🟢 起動を開始しました。接続可能まで数分かかります。完了したら通知します。",
    },
  });
}

/**
 * `/restart` コマンドを処理する。MOD 更新（S3 world/）を取り込み直すため
 * 稼働インスタンスを作り直す。
 *   - 稼働中: 稼働インスタンスを ASG から終了する（desired は維持＝ASGが新インスタンスを起動）。
 *             新インスタンスは UserData で S3 最新の MOD 構成を取り込んで起動する。
 *   - 停止中: desired=1 で起動する（結果的に最新 MOD 構成で起動する）。
 *
 * @returns {Promise<object>} Discord へ返す type=4 レスポンス
 */
async function handleRestartCommand() {
  const group = await describeTargetGroup();
  if (!group) {
    return groupNotFoundResponse();
  }

  const instanceIds = runningInstanceIds(group);
  if (instanceIds.length === 0) {
    await startDesiredCapacity();
    return jsonResponse(200, {
      type: RESPONSE_TYPE_CHANNEL_MESSAGE,
      data: {
        content:
          "🟢 停止中だったため起動を開始しました（最新MOD構成・数分かかります）。",
      },
    });
  }

  // desired は維持したままインスタンスのみ終了させ、ASG に新インスタンスを起動させる。
  // 通常は1台だが、想定外に複数稼働していても全て作り直す。
  await Promise.all(
    instanceIds.map((instanceId) =>
      autoScalingClient.send(
        new TerminateInstanceInAutoScalingGroupCommand({
          InstanceId: instanceId,
          ShouldDecrementDesiredCapacity: false,
        })
      )
    )
  );

  return jsonResponse(200, {
    type: RESPONSE_TYPE_CHANNEL_MESSAGE,
    data: {
      content:
        "🔄 再起動を開始しました。最新のMOD構成で数分後に起動します（接続中の方は一旦切断されます）。",
    },
  });
}

/**
 * APPLICATION_COMMAND をコマンド名で対応するハンドラへ振り分ける。
 *
 * @param {object} interaction Discord Interaction オブジェクト
 * @returns {Promise<object>} Discord へ返す type=4 レスポンス
 */
function handleApplicationCommand(interaction) {
  switch (interaction.data?.name) {
    case "start":
      return handleStartCommand();
    case "restart":
      return handleRestartCommand();
    default:
      return jsonResponse(200, {
        type: RESPONSE_TYPE_CHANNEL_MESSAGE,
        data: { content: "未対応のコマンドです。" },
      });
  }
}

/**
 * Lambda Function URL のエントリポイント。
 *
 * @param {object} event Function URL の Lambda Proxy イベント
 * @returns {Promise<object>} Function URL 形式のレスポンス
 */
export const handler = async (event) => {
  const headers = event.headers ?? {};
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : event.body ?? "";

  const isValid = await verifySignature(
    rawBody,
    headers["x-signature-ed25519"],
    headers["x-signature-timestamp"]
  );
  if (!isValid) {
    return jsonResponse(401, { error: "invalid request signature" });
  }

  const interaction = JSON.parse(rawBody);

  if (interaction.type === INTERACTION_TYPE_PING) {
    return jsonResponse(200, { type: RESPONSE_TYPE_PONG });
  }

  if (interaction.type === INTERACTION_TYPE_APPLICATION_COMMAND) {
    return handleApplicationCommand(interaction);
  }

  return jsonResponse(200, {
    type: RESPONSE_TYPE_CHANNEL_MESSAGE,
    data: { content: "未対応の操作です。" },
  });
};
