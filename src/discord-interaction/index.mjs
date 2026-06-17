// Discord Interactions Webhook を処理する受付 Lambda（Function URL 経由 / nodejs24.x / ESM）
//
// 役割:
//   - Lambda Function URL に登録された Discord Interactions Endpoint としてリクエストを受ける
//   - Ed25519 署名検証（不正は 401）
//   - type=1(PING) には {type:1} を返す
//   - type=2(APPLICATION_COMMAND) は worker Lambda を非同期 invoke し、
//     即座に type=5(DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE) を返す
//
// 設計意図:
//   Discord interaction には「3秒以内に応答」の制限がある。ASG 操作（Describe→SetDesiredCapacity 等）
//   は数秒かかり同期では間に合わないため、重い処理は worker Lambda へ逃がし、受付は deferred を即返す。
//   実際の処理結果は worker が followup（webhook PATCH）でメッセージを更新して伝える。
//
// 環境変数:
//   DISCORD_PUBLIC_KEY_SSM   ... Discord アプリ公開鍵を保持する SSM パラメータ名
//   WORKER_FUNCTION_NAME     ... 重い処理を非同期実行する worker Lambda の関数名
//
// AWS SDK v3 / Node 標準 crypto は nodejs24.x ランタイムに同梱されるため依存追加は不要。

import crypto from "node:crypto";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";

// Lambda 実行環境では AWS_REGION が自動設定される。ローカルでの静的検証等に備えて
// フォールバックのみ残し、CFn が渡す REGION env には依存しない。
const REGION = process.env.AWS_REGION ?? "ap-northeast-1";

const ssmClient = new SSMClient({ region: REGION });
const lambdaClient = new LambdaClient({ region: REGION });

// Discord Interaction の type / response type
const INTERACTION_TYPE_PING = 1;
const INTERACTION_TYPE_APPLICATION_COMMAND = 2;
const RESPONSE_TYPE_PONG = 1;
const RESPONSE_TYPE_DEFERRED_MESSAGE = 5;

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

/**
 * 重い処理（ASG 操作 + followup）を worker Lambda へ非同期 invoke する。
 * InvocationType=Event で投げっぱなしにし、結果は worker 側が followup で伝える。
 *
 * @param {object} interaction Discord Interaction オブジェクト
 * @returns {Promise<void>}
 */
async function invokeWorker(interaction) {
  await lambdaClient.send(
    new InvokeCommand({
      FunctionName: process.env.WORKER_FUNCTION_NAME,
      InvocationType: "Event",
      Payload: Buffer.from(
        JSON.stringify({
          commandName: interaction.data?.name,
          token: interaction.token,
          applicationId: interaction.application_id,
        })
      ),
    })
  );
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
    // worker へ重い処理を委譲し、3秒制限内に deferred 応答を返す。
    await invokeWorker(interaction);
    return jsonResponse(200, { type: RESPONSE_TYPE_DEFERRED_MESSAGE });
  }

  return jsonResponse(200, { type: RESPONSE_TYPE_DEFERRED_MESSAGE });
};
