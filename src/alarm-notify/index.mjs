// CloudWatch Alarm / スポット容量失敗イベントを Discord Webhook へ通知する Lambda
// （nodejs24.x / ESM）
//
// 入力2系統を判別して処理する:
//   (a) SNS 経由の CloudWatch Alarm 通知（event.Records[].Sns.Message に Alarm JSON）
//   (b) EventBridge 経由の "EC2 Instance Launch Unsuccessful"（スポット容量確保失敗）
//
// ※ インスタンス起動完了通知は、インスタンス側スクリプトが直接 Webhook を叩くため
//    本 Lambda は受けない（SNS / EventBridge のみ対象）。
//
// 環境変数:
//   DISCORD_WEBHOOK_SSM ... Discord Webhook URL を保持する SSM パラメータ名(SecureString)
//
// AWS SDK v3 / fetch は nodejs24.x ランタイムで利用可能なため依存追加は不要。

import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

// Lambda 実行環境では AWS_REGION が自動設定される。ローカルでの静的検証等に備えて
// フォールバックのみ残し、CFn が渡す REGION env には依存しない。
const REGION = process.env.AWS_REGION ?? "ap-northeast-1";

const ssmClient = new SSMClient({ region: REGION });

// SSM から取得した Webhook URL をコールドスタート時に1回だけ取得しキャッシュする
let cachedWebhookUrl = null;

/**
 * Discord Webhook URL を SSM から取得する（取得後はモジュールスコープにキャッシュ）。
 *
 * @returns {Promise<string>} Webhook URL
 */
async function getWebhookUrl() {
  if (cachedWebhookUrl) {
    return cachedWebhookUrl;
  }

  const { Parameter } = await ssmClient.send(
    new GetParameterCommand({
      Name: process.env.DISCORD_WEBHOOK_SSM,
      WithDecryption: true,
    })
  );
  cachedWebhookUrl = Parameter.Value.trim();
  return cachedWebhookUrl;
}

/**
 * CloudWatch Alarm の JSON から Discord 通知文を整形する。
 *
 * @param {object} alarm SNS メッセージをパースした Alarm オブジェクト
 * @returns {string} 通知本文
 */
const COMPARISON_LABELS = {
  GreaterThanThreshold: "以上",
  GreaterThanOrEqualToThreshold: "以上",
  LessThanThreshold: "以下",
  LessThanOrEqualToThreshold: "以下",
};

function formatAlarmMessage(alarm) {
  const trigger = alarm.Trigger ?? {};
  const icon = alarm.NewStateValue === "ALARM" ? "🔴" : "🟢";
  const op = COMPARISON_LABELS[trigger.ComparisonOperator] ?? trigger.ComparisonOperator ?? "-";
  const lines = [
    `${icon} **CloudWatch Alarm: ${alarm.AlarmName}**`,
    `状態: ${alarm.OldStateValue} → ${alarm.NewStateValue}`,
    `メトリクス: ${trigger.Namespace ?? "-"} / ${trigger.MetricName ?? "-"}`,
    `しきい値: ${trigger.Threshold ?? "-"}${op}` +
      ` (${trigger.EvaluationPeriods ?? "-"} × ${trigger.Period ?? "-"}s)`,
    `理由: ${alarm.NewStateReason ?? "-"}`,
  ];
  return lines.join("\n");
}

/**
 * "EC2 Instance Launch Unsuccessful"（スポット容量失敗）の整形を行う。
 *
 * @param {object} event EventBridge イベント
 * @returns {string} 通知本文
 */
function formatLaunchFailureMessage(event) {
  const detail = event.detail ?? {};
  const lines = [
    "🟠 **スポットインスタンスの起動に失敗しました**",
    `ASG: ${detail.AutoScalingGroupName ?? "-"}`,
    `理由: ${detail.Cause ?? detail.StatusMessage ?? "-"}`,
    "容量が確保でき次第 ASG が自動でリトライします。しばらくお待ちください。",
  ];
  return lines.join("\n");
}

/**
 * Lambda イベントから Discord へ送る通知本文を組み立てる。
 * SNS(CloudWatch Alarm) と EventBridge(起動失敗) を判別する。
 *
 * @param {object} event Lambda イベント
 * @returns {string|null} 通知本文（対象外イベントなら null）
 */
function buildContent(event) {
  // (a) SNS 経由の CloudWatch Alarm
  const snsMessage = event.Records?.[0]?.Sns?.Message;
  if (snsMessage) {
    return formatAlarmMessage(JSON.parse(snsMessage));
  }

  // (b) EventBridge 経由のスポット起動失敗
  if (event["detail-type"] === "EC2 Instance Launch Unsuccessful") {
    return formatLaunchFailureMessage(event);
  }

  return null;
}

/**
 * Lambda エントリポイント。イベントを整形して Discord Webhook へ POST する。
 *
 * @param {object} event SNS または EventBridge のイベント
 * @returns {Promise<object>} 処理結果（statusCode）
 */
export const handler = async (event) => {
  const content = buildContent(event);
  if (!content) {
    console.warn("対象外のイベントを受信しました", JSON.stringify(event));
    return { statusCode: 204 };
  }

  const response = await fetch(await getWebhookUrl(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ content }),
  });

  if (!response.ok) {
    // Webhook 送信失敗はリトライ判断のため呼び出し元へ伝播させる
    throw new Error(
      `Discord Webhook POST failed: ${response.status} ${await response.text()}`
    );
  }

  return { statusCode: 200 };
};
