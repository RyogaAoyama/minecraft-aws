#!/bin/bash
#
# /var/log/minecraft-metrics/<kind>.jsonl を rotate → gzip → S3 へ upload する。
#
# 呼び出し経路:
#   - minecraft-flush-metrics.timer (5 分ごと)
#   - minecraft.service の ExecStop 連鎖 (停止時の最終 flush)
#
# 多重実行ガード:
#   - /run/minecraft-flush.lock (全体): 2 重起動なら 2 番目は即 exit
#   - /run/minecraft-metrics-<kind>.lock (per-kind): collector の append と race しない
#     ように rotate (mv) の瞬間だけ取る
#
# S3 レイアウト:
#   s3://${OPS_LOGS_BUCKET}/metrics/<kind>/year=YYYY/month=MM/day=DD/hour=HH/instance=<id>/data-<ts>.jsonl.gz
#
# 失敗時: upload 失敗は次回 flush で .gz が残っているため再送可。
# Spot 中断 grace (120s) 内に終わるよう aws s3 cp に短いタイムアウトを掛ける。
#
# OPS_LOGS_BUCKET は将来 /etc/minecraft.env から取れるようにしたいが、Phase 1 ではハードコード。

# 観測の失敗で本体停止フローを止めないため set -e は使わず各段で || true / continue する。
set -uo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=metrics-common.sh
source "$(dirname "$0")/metrics-common.sh"

# Phase 1 時点では /etc/minecraft.env に OPS_LOGS_BUCKET が無いため default を入れる。
# 命名規約: minecraft-ops-logs-prd は Resource.yml で定義済みの ops ログ用バケット。
: "${OPS_LOGS_BUCKET:=minecraft-ops-logs-prd}"

LOCK_FILE=/run/minecraft-flush.lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another flush is running; skip"
    exit 0
fi

# IMDSv2 で自インスタンス ID を取得。失敗なら upload 不能なので abort。
function metrics_instance_id {
    local token
    token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/instance-id"
}
INSTANCE_ID=$(metrics_instance_id || true)
if [ -z "${INSTANCE_ID:-}" ]; then
    echo "warn: could not resolve instance-id via IMDS; abort flush"
    exit 0
fi

# GC log の JSONL 変換 hook (parse-gc-log.sh は Phase 2 で追加。存在すれば実行)
PARSE_GC="$(dirname "$0")/parse-gc-log.sh"
if [ -x "$PARSE_GC" ]; then
    bash "$PARSE_GC" || echo "warn: parse-gc-log.sh failed"
fi

HOUR_PATH="year=$(date -u +%Y)/month=$(date -u +%m)/day=$(date -u +%d)/hour=$(date -u +%H)/instance=${INSTANCE_ID}"

# 全 kind について rotate → gz → upload を試みる。1 つ失敗しても次に進む。
for kind in iostat node_snapshot gc save_sync startup; do
    live="${METRICS_LOG_DIR}/${kind}.jsonl"
    [ -s "$live" ] || continue
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    rotated="${METRICS_LOG_DIR}/${kind}.${ts}.jsonl"

    # collector の append と競合しないよう per-kind flock を取って mv する。
    # lock 保持時間は mv の数 ms のみ。
    (
        flock 8
        mv "$live" "$rotated"
    ) 8>"/run/minecraft-metrics-${kind}.lock" || {
        echo "warn: rotate failed for ${kind}; skip"
        continue
    }

    if ! gzip -f "$rotated"; then
        echo "warn: gzip failed for ${rotated}; leave as-is for next retry"
        continue
    fi

    key="metrics/${kind}/${HOUR_PATH}/data-${ts}.jsonl.gz"
    if aws s3 cp "${rotated}.gz" "s3://${OPS_LOGS_BUCKET}/${key}" \
            --region "$AWS_REGION" \
            --cli-read-timeout 10 \
            --cli-connect-timeout 5 >/dev/null; then
        rm -f "${rotated}.gz"
    else
        echo "warn: s3 upload failed for ${kind}; will retry next flush (${rotated}.gz retained)"
    fi
done
