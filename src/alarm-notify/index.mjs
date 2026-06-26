// CloudWatch Alarm / スポット容量失敗 / スポット中断イベントを Discord Webhook へ通知し、
// 中断イベントについては Spot Advisor JSON のスナップショットを S3 に保存する Lambda
// （nodejs24.x / ESM）
//
// 入力3系統を判別して処理する:
//   (a) SNS 経由の CloudWatch Alarm 通知
//   (b) EventBridge: "EC2 Instance Launch Unsuccessful"（スポット容量確保失敗）
//   (c) EventBridge: "EC2 Spot Instance Interruption Warning"（中断2分前通知）
//        → Spot Advisor JSON を fetch して S3 に丸ごと保存(後で分析する用)
//
// 環境変数:
//   DISCORD_WEBHOOK_SSM ... Discord Webhook URL を保持する SSM パラメータ名(SecureString)
//   OPS_LOGS_BUCKET     ... Spot 中断ログの保存先 S3 バケット名

import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

const REGION = process.env.AWS_REGION ?? "ap-northeast-1";
const SPOT_ADVISOR_URL = "https://spot-bid-advisor.s3.amazonaws.com/spot-advisor-data.json";

const ssm = new SSMClient({ region: REGION });
const s3 = new S3Client({ region: REGION });

let cachedWebhookUrl = null;

async function getWebhookUrl() {
  if (cachedWebhookUrl) return cachedWebhookUrl;
  const { Parameter } = await ssm.send(new GetParameterCommand({
    Name: process.env.DISCORD_WEBHOOK_SSM,
    WithDecryption: true,
  }));
  cachedWebhookUrl = Parameter.Value.trim();
  return cachedWebhookUrl;
}

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
  return [
    `${icon} **CloudWatch Alarm: ${alarm.AlarmName}**`,
    `状態: ${alarm.OldStateValue} → ${alarm.NewStateValue}`,
    `メトリクス: ${trigger.Namespace ?? "-"} / ${trigger.MetricName ?? "-"}`,
    `しきい値: ${trigger.Threshold ?? "-"}${op} (${trigger.EvaluationPeriods ?? "-"} × ${trigger.Period ?? "-"}s)`,
    `理由: ${alarm.NewStateReason ?? "-"}`,
  ].join("\n");
}

function formatLaunchFailureMessage(event) {
  const detail = event.detail ?? {};
  return [
    "🟠 **スポットインスタンスの起動に失敗しました**",
    `ASG: ${detail.AutoScalingGroupName ?? "-"}`,
    `理由: ${detail.Cause ?? detail.StatusMessage ?? "-"}`,
    "容量が確保でき次第 ASG が自動でリトライします。しばらくお待ちください。",
  ].join("\n");
}

async function handleSpotInterruption(event) {
  const ts = event.time;
  const instanceId = event.detail["instance-id"];
  const advisor = await (await fetch(SPOT_ADVISOR_URL)).text();

  await s3.send(new PutObjectCommand({
    Bucket: process.env.OPS_LOGS_BUCKET,
    Key: `spot-interruptions/${ts.slice(0, 10)}/${ts}-${instanceId}.json`,
    Body: advisor,
    ContentType: "application/json",
  }));

  return `🟡 **スポット中断検知** ${instanceId}（2分後に強制返却 → ASG が別プールで再起動）`;
}

async function buildContent(event) {
  const snsMessage = event.Records?.[0]?.Sns?.Message;
  if (snsMessage) return formatAlarmMessage(JSON.parse(snsMessage));

  if (event["detail-type"] === "EC2 Instance Launch Unsuccessful") {
    return formatLaunchFailureMessage(event);
  }

  if (event["detail-type"] === "EC2 Spot Instance Interruption Warning") {
    return handleSpotInterruption(event);
  }

  return null;
}

export const handler = async (event) => {
  const content = await buildContent(event);
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
    throw new Error(`Discord Webhook POST failed: ${response.status} ${await response.text()}`);
  }

  return { statusCode: 200 };
};
