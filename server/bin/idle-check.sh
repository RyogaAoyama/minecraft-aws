#!/bin/bash
#
# アイドル監視。idle-check.timer から毎分呼ばれる。
#
# RCON `list` でオンライン人数を取得し:
#   - 0人        … 連続カウンタを +1
#   - 1人以上     … カウンタを 0 にリセット
# カウンタが IDLE_LIMIT(=10) に達したら（=1分間隔×10=10分連続0人）、
# save-and-sync で保存後、自インスタンスを ASG から終了させ desired を 0 に戻す。
#
# `list` の出力例:
#   "There are 0 of a max of 10 players online:"
# から先頭の人数を取り出して判定する。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-rcon.sh
source "$(dirname "$0")/mc-rcon.sh"
# shellcheck source=mc-notify.sh
source "$(dirname "$0")/mc-notify.sh"

SCRIPT_DIR="$(dirname "$0")"
COUNTER_FILE="/var/lib/minecraft/idle_count"
IDLE_LIMIT=10

# IMDSv2 で自インスタンスIDを取得する。
#
# 出力: instance-id（例: i-0123456789abcdef0）
function self_instance_id {
    local token
    token="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/instance-id"
}

mkdir -p "$(dirname "$COUNTER_FILE")"

# RCON list を実行。サーバー起動直後などで応答が無ければ今回はスキップ（カウンタ据え置き）。
if ! LIST_OUTPUT="$(mc_rcon list)"; then
    echo "warn: RCON list failed; skip this cycle"
    exit 0
fi

# "There are N of a max of ..." の N を取り出す。
PLAYER_COUNT="$(echo "$LIST_OUTPUT" | grep -oE 'are [0-9]+' | grep -oE '[0-9]+' | head -n1)"
if [ -z "$PLAYER_COUNT" ]; then
    echo "warn: could not parse player count from: $LIST_OUTPUT"
    exit 0
fi

if [ "$PLAYER_COUNT" -gt 0 ]; then
    echo "0" > "$COUNTER_FILE"
    echo "players online: $PLAYER_COUNT; idle counter reset"
    exit 0
fi

# 0人。カウンタを進める。
CURRENT="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"
NEXT=$((CURRENT + 1))
echo "$NEXT" > "$COUNTER_FILE"
echo "no players online; idle counter: $NEXT/$IDLE_LIMIT"

if [ "$NEXT" -lt "$IDLE_LIMIT" ]; then
    exit 0
fi

echo "idle limit reached; saving and terminating instance"
bash "$SCRIPT_DIR/save-and-sync.sh"

# 自インスタンスID取得に失敗(空文字)した場合は、--instance-id "" で API を誤呼び出し
# しないようスキップする。save は済んでいるので、次サイクルで再度終了を試みる。
INSTANCE_ID="$(self_instance_id || true)"
if [ -z "$INSTANCE_ID" ]; then
    echo "warn: could not resolve self instance-id; skip termination this cycle"
    exit 0
fi

# terminate するとインスタンスが落ちて通知できなくなるため、終了 API 呼び出しの前に通知する。
mc_notify "💤 10分間プレイヤーがいなかったため、ワールドを保存してサーバーを停止しました。"

aws autoscaling terminate-instance-in-auto-scaling-group \
    --region "$AWS_REGION" \
    --instance-id "$INSTANCE_ID" \
    --should-decrement-desired-capacity
