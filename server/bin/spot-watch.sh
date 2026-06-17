#!/bin/bash
#
# スポット中断/停止通知の監視デーモン。spot-watch.service から常駐起動される。
#
# IMDSv2 の spot/instance-action を3秒間隔でポーリングし、
# 通知が出た（HTTP 404 以外＝中断/停止スケジュール）瞬間に save-and-sync を実行する。
# スポット中断猶予は約2分なので、検知遅延を抑えるため短い間隔でポーリングする。
#
# save-and-sync 自体は flock で多重実行ガードされるため、ExecStop と同時に走っても安全。
# 一度発火したら sync 後にループを抜ける（同じ中断で何度も sync しない）。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-notify.sh
source "$(dirname "$0")/mc-notify.sh"

SCRIPT_DIR="$(dirname "$0")"
POLL_INTERVAL=3
METADATA_URL="http://169.254.169.254/latest/meta-data/spot/instance-action"

# IMDSv2 トークンを取得する（短命なので毎ポーリングで更新する）。
function imds_token {
    curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 30"
}

echo "spot-watch started; polling every ${POLL_INTERVAL}s"

while true; do
    TOKEN="$(imds_token || true)"

    # instance-action が存在すれば（HTTP 200）中断通知あり。404 なら通知なし。
    if [ -n "$TOKEN" ] && curl -sf \
        -H "X-aws-ec2-metadata-token: $TOKEN" \
        "$METADATA_URL" >/dev/null 2>&1; then
        echo "spot interruption notice detected; running save-and-sync"
        bash "$SCRIPT_DIR/save-and-sync.sh"
        # save（データ保護）を済ませてから通知する。
        mc_notify "⚠️ スポットインスタンスが中断されました。ワールドを保存して停止します。再開するには /start を実行してください。"
        echo "save-and-sync done; spot-watch exiting"
        break
    fi

    sleep "$POLL_INTERVAL"
done
