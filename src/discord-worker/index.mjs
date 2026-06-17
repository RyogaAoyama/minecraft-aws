// Discord スラッシュコマンドの重い処理を非同期実行する worker Lambda（nodejs24.x / ESM）
//
// 役割:
//   - 受付 Lambda(discord-interaction) から非同期 invoke されるイベントを処理する
//   - ASG 操作で `/start` / `/restart` / `/stop` を実行する
//       - `/start`   ... 停止中なら ASG の desired を 0->1 にして起動
//       - `/restart` ... 稼働中なら現インスタンスを終了して最新 MOD 構成で作り直し、
//                          停止中なら desired=1 で起動（MOD更新を S3 から取り込み直す用途）
//       - `/stop`    ... 稼働中なら現インスタンスを終了し desired を減らして停止（再起動させない）
//   - 処理結果を Discord の followup（webhook PATCH @original）でメッセージ更新して伝える
//
// イベント:
//   { commandName: string, token: string, applicationId: string }
//     commandName   ... スラッシュコマンド名（start / restart 等）
//     token         ... interaction token（followup の認証に使う。Bot Token は不要）
//     applicationId ... Discord アプリ ID
//
// 環境変数:
//   ASG_NAME   ... 起動対象の Auto Scaling Group 名（minecraft-asg-prd）
//
// AWS SDK v3 / fetch は nodejs24.x ランタイムに同梱されるため依存追加は不要。

import {
  AutoScalingClient,
  DescribeAutoScalingGroupsCommand,
  SetDesiredCapacityCommand,
  TerminateInstanceInAutoScalingGroupCommand,
} from "@aws-sdk/client-auto-scaling";

// Lambda 実行環境では AWS_REGION が自動設定される。ローカルでの静的検証等に備えてフォールバックのみ残す。
const REGION = process.env.AWS_REGION ?? "ap-northeast-1";

const autoScalingClient = new AutoScalingClient({ region: REGION });

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
 * @returns {Promise<string>} followup で表示するメッセージ
 */
async function handleStartCommand() {
  const group = await describeTargetGroup();
  if (!group) {
    return "⚠️ サーバー構成が見つかりませんでした。管理者に連絡してください。";
  }

  if (!isStopped(group)) {
    return "🟡 既に起動中です（または起動済み）。";
  }

  await startDesiredCapacity();

  return "⏳ 起動処理を受け付けました。Minecraftの起動が完了したら通知します（数分かかります）。";
}

/**
 * `/restart` コマンドを処理する。MOD 更新（S3 world/）を取り込み直すため
 * 稼働インスタンスを作り直す。
 *   - 稼働中: 稼働インスタンスを ASG から終了する（desired は維持＝ASGが新インスタンスを起動）。
 *             新インスタンスは UserData で S3 最新の MOD 構成を取り込んで起動する。
 *   - 停止中: desired=1 で起動する（結果的に最新 MOD 構成で起動する）。
 *
 * @returns {Promise<string>} followup で表示するメッセージ
 */
async function handleRestartCommand() {
  const group = await describeTargetGroup();
  if (!group) {
    return "⚠️ サーバー構成が見つかりませんでした。管理者に連絡してください。";
  }

  const instanceIds = runningInstanceIds(group);
  if (instanceIds.length === 0) {
    await startDesiredCapacity();
    return "⏳ 停止中だったため起動処理を受け付けました。完了したら通知します（最新MOD構成・数分）。";
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

  return "⏳ 再起動処理を受け付けました。最新MOD構成での起動が完了したら通知します（接続中の方は一旦切断されます）。";
}

/**
 * `/stop` コマンドを処理する。稼働インスタンスを終了して desired を減らし、
 * サーバーを停止する（restart と異なり ASG に作り直させない）。
 *   - 稼働中: 稼働インスタンスを終了し ShouldDecrementDesiredCapacity:true で desired を減らす。
 *             restart は desired 維持（作り直し）なのと対になる挙動。
 *   - 停止中: 何もせず既に停止している旨を返す。
 *
 * ワールド保存は worker からは行わない。worker は VPC 外で RCON を叩けないため、
 * ASG terminate によるインスタンスの正常シャットダウン → minecraft.service の ExecStop →
 * save-and-sync で保存される、という既存設計（idle-check.sh と同様）に委ねる。
 *
 * @returns {Promise<string>} followup で表示するメッセージ
 */
async function handleStopCommand() {
  const group = await describeTargetGroup();
  if (!group) {
    return "⚠️ サーバー構成が見つかりませんでした。管理者に連絡してください。";
  }

  const instanceIds = runningInstanceIds(group);
  if (instanceIds.length === 0) {
    return "🟡 既に停止しています。";
  }

  // desired を減らしてインスタンスを終了させ、ASG に再起動させない。
  // 通常は1台だが、想定外に複数稼働していても全て停止する。
  await Promise.all(
    instanceIds.map((instanceId) =>
      autoScalingClient.send(
        new TerminateInstanceInAutoScalingGroupCommand({
          InstanceId: instanceId,
          ShouldDecrementDesiredCapacity: true,
        })
      )
    )
  );

  return "🛑 停止を開始しました。ワールドを保存して停止します。";
}

/**
 * コマンド名に対応する処理を実行し、followup で表示するメッセージを返す。
 *
 * @param {string} commandName スラッシュコマンド名
 * @returns {Promise<string>} followup で表示するメッセージ
 */
function handleCommand(commandName) {
  switch (commandName) {
    case "start":
      return handleStartCommand();
    case "restart":
      return handleRestartCommand();
    case "stop":
      return handleStopCommand();
    default:
      return Promise.resolve("未対応のコマンドです。");
  }
}

/**
 * deferred 応答（type=5）で表示中の「考え中」メッセージを followup で更新する。
 * interaction token 自体が認証になるため Bot Token 等の認証ヘッダは不要。
 *
 * @param {string} applicationId Discord アプリ ID
 * @param {string} token interaction token
 * @param {string} content 表示するメッセージ
 * @returns {Promise<void>}
 */
async function updateOriginalMessage(applicationId, token, content) {
  await fetch(
    `https://discord.com/api/v10/webhooks/${applicationId}/${token}/messages/@original`,
    {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content }),
    }
  );
}

/**
 * 受付 Lambda から非同期 invoke される worker のエントリポイント。
 *
 * @param {object} event { commandName, token, applicationId }
 * @returns {Promise<void>}
 */
export const handler = async (event) => {
  const { commandName, token, applicationId } = event;

  try {
    const content = await handleCommand(commandName);
    await updateOriginalMessage(applicationId, token, content);
  } catch (error) {
    // 例外時に deferred を放置すると Discord 側が「考え中」のまま残るため、必ず followup で伝える。
    console.error("worker command failed", error);
    await updateOriginalMessage(
      applicationId,
      token,
      "⚠️ 起動処理でエラーが発生しました。ログを確認してください。"
    );
  }
};
