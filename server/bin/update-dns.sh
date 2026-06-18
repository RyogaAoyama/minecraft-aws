#!/bin/bash
#
# DuckDNS の A レコードを自インスタンスのパブリック IP で更新する。
# 起動直後に install.sh から呼ばれ、ドメイン名でプレイヤーが接続できるようにする。
#
# DuckDNS トークンは SSM Parameter Store(SecureString) から取得し、ファイルに残さない。
# API のタイミング揺れに備え指数バックオフでリトライし、
# 最終的に失敗したら Discord へ通知して可視化する。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-notify.sh
source "$(dirname "$0")/mc-notify.sh"

MAX_ATTEMPTS=5

# IMDSv2 でパブリック IP を取得する。
function self_public_ip {
    local token
    token="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/public-ipv4"
}

# DuckDNS ドメイン・トークンを SSM から取得する。
DUCKDNS_DOMAIN="$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$DUCKDNS_DOMAIN_SSM" \
    --query "Parameter.Value" \
    --output text)"
DUCKDNS_TOKEN="$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$DUCKDNS_TOKEN_SSM" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text)"

PUBLIC_IP="$(self_public_ip)"
echo "updating DuckDNS: ${DUCKDNS_DOMAIN}.duckdns.org -> $PUBLIC_IP"

# 指数バックオフ: 2,4,8,16秒 と待機しながら最大 MAX_ATTEMPTS 回試行する。
DELAY=2
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    RESPONSE="$(curl -sf \
        "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}" \
        2>/dev/null || echo "FAIL")"

    if [ "$RESPONSE" = "OK" ]; then
        echo "DuckDNS updated successfully"
        exit 0
    fi

    echo "DuckDNS update failed (attempt $attempt/$MAX_ATTEMPTS); retrying in ${DELAY}s"
    sleep "$DELAY"
    DELAY=$((DELAY * 2))
done

echo "error: DuckDNS update failed after $MAX_ATTEMPTS attempts"
mc_notify "🔴 DuckDNS の更新に失敗しました（domain: ${DUCKDNS_DOMAIN}.duckdns.org）。ドメイン名での接続ができない可能性があります。"
exit 1
