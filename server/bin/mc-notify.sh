#!/bin/bash
#
# Discord Webhook 通知の共通ラッパ。
# 他の管理スクリプトから `source` して `mc_notify "<message>"` で呼び出す。
#
# Webhook URL は SSM Parameter Store(SecureString) から都度取得し、ファイルに残さない。
# 通知失敗（SSM 取得失敗 / POST 失敗）は致命としない（運用通知が落ちても本体は継続する）。
#
# 前提: 呼び出し元が事前に /etc/minecraft.env を source していること
#       （AWS_REGION / DISCORD_WEBHOOK_SSM を参照する）。

# Discord Webhook へメッセージを POST する。
#
# 引数: $1 通知本文（Discord の content フィールドに入る文字列）
# 戻り値: 常に 0（通知失敗でも呼び出し元を止めない）
function mc_notify {
    local message="$1"
    local webhook_url

    webhook_url="$(aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$DISCORD_WEBHOOK_SSM" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text 2>/dev/null)" || {
        echo "warn: failed to fetch Discord webhook URL from SSM; skip notify"
        return 0
    }

    # content を JSON 文字列として安全に組み立てる（改行・引用符をエスケープ）。
    local payload
    payload="$(printf '%s' "$message" | python3 -c \
        'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')"

    curl -sf -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || {
        echo "warn: Discord webhook POST failed; continuing"
        return 0
    }
}
