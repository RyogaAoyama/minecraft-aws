#!/bin/bash
#
# Elastic IP を自インスタンスへ関連付ける。
# 起動直後に install.sh から呼ばれ、固定IPでプレイヤーが接続できるようにする。
#
# 前インスタンスが異常終了して EIP が残留している場合でも associate-address は
# 付け替えで成功するため、明示的な disassociate は行わない。
# API のタイミング揺れ（インスタンス登録直後など）に備え指数バックオフでリトライし、
# 最終的に失敗したら Discord へ通知して可視化する（固定IPで繋げない障害は致命的）。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-notify.sh
source "$(dirname "$0")/mc-notify.sh"

MAX_ATTEMPTS=5

# IMDSv2 で自インスタンスIDを取得する。
function self_instance_id {
    local token
    token="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/instance-id"
}

INSTANCE_ID="$(self_instance_id)"
echo "associating EIP $EIP_ALLOCATION_ID to $INSTANCE_ID"

# 指数バックオフ: 2,4,8,16秒 と待機しながら最大 MAX_ATTEMPTS 回試行する。
DELAY=2
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if aws ec2 associate-address \
        --region "$AWS_REGION" \
        --allocation-id "$EIP_ALLOCATION_ID" \
        --instance-id "$INSTANCE_ID" \
        --allow-reassociation; then
        echo "EIP associated successfully"
        exit 0
    fi

    echo "associate-address failed (attempt $attempt/$MAX_ATTEMPTS); retrying in ${DELAY}s"
    sleep "$DELAY"
    DELAY=$((DELAY * 2))
done

echo "error: EIP association failed after $MAX_ATTEMPTS attempts"
mc_notify "🔴 EIPの関連付けに失敗しました（allocation: ${EIP_ALLOCATION_ID} / instance: ${INSTANCE_ID}）。固定IPでの接続ができない可能性があります。"
exit 1
