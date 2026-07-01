#!/bin/bash
#
# スポット中断/停止通知の監視デーモン。spot-watch.service から常駐起動される。
#
# IMDSv2 の spot/instance-action を3秒間隔でポーリングし、通知を検知したら
# 「次の spot を立ち上げる」前準備だけを行う。フローは以下：
#
#   1. world を S3 へ事前 save+sync する（新インスタンスが最新世界で起動できるよう）
#   2. SSM /minecraft/prd/handover-state を STANDBY_REQUESTED に書く
#   3. ASG desired を 1 -> 2 に増やして次のインスタンスを起動させる
#   4. SSM を polling して新インスタンスが STANDBY_READY になるのを待つ（最大 ~90秒）
#   5. ready なら DuckDNS の A レコードを新 IP に切り替える
#         （プレイヤーは旧サーバー切断後に手動再接続すれば新 IP へ繋がる）
#   6. ready が間に合わなかった場合（タイムアウト・呼び出し失敗）:
#        save-and-sync.sh だけ走らせて死ぬ（データ保全のみ、次回起動でリセット）
#   7. SSM handover-state を IDLE に戻して終了
#
# 注: クライアントへの自動再接続誘導（ServerTransferS2CPacket / RCON /transfer-all）は
#     クライアント側 Netty 4.2 の NPE レースで安定しなかったため一旦撤去。
#     プレイヤーは disconnect 表示後、Reconnect ボタンで自分で繋ぎ直す運用。
#     DuckDNS は既に新 IP を指してるので Reconnect 1 回で新サーバーへ繋がる。
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

HANDOVER_STATE_PARAM="/minecraft/prd/handover-state"
STANDBY_IP_PARAM="/minecraft/prd/standby-ip"
# standby が ready になるまでの最大待ち時間（秒）。
# 実測: 新インスタンスの UserData〜MC ready が 30-40 秒程度なので 90 秒あれば十分余裕。
# スポット中断の猶予 2 分（120 秒）に対しても余裕を残す。
STANDBY_WAIT_MAX_SECONDS=90

# IMDSv2 トークンを取得する（短命なので毎ポーリングで更新する）。
function imds_token {
    curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 30"
}

# 中断検知時にハンドオーバーを試行する。
# 成否を返し、呼び出し側は失敗時に従来の save-and-sync フォールバックへ落とす。
# 戻り値: 0=ハンドオーバー成功 / 1=失敗（フォールバックすべき）
function try_handover {
    # === Phase 0: standby が「最新の world」で起動できるよう先に save+sync ===
    # 順序が重要: standby が install.sh の Step3 で S3 から world を取り込む時点で、
    # 「中断検知直前の状態」が S3 に載っている必要がある（さもないと world-sync.timer の
    # 最後の save 時点まで巻き戻る）。
    # この save が遅れると最大 5 分（world-sync.timer の周期）分の進捗が standby に
    # 反映されない問題が起きる。
    echo "handover: pre-save world before launching standby (critical for data freshness)"
    bash "$SCRIPT_DIR/save-and-sync.sh" || {
        echo "handover: pre-save failed; continue anyway (standby will use last periodic save)"
    }

    echo "handover: marking STANDBY_REQUESTED in SSM"
    aws ssm put-parameter \
        --region "$AWS_REGION" \
        --name "$HANDOVER_STATE_PARAM" \
        --value "STANDBY_REQUESTED" \
        --type String \
        --overwrite >/dev/null || {
            echo "handover: SSM put STANDBY_REQUESTED failed"
            return 1
        }

    echo "handover: scaling ASG $ASG_NAME desired 1 -> 2"
    aws autoscaling set-desired-capacity \
        --region "$AWS_REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-capacity 2 \
        --honor-cooldown >/dev/null 2>&1 || \
    aws autoscaling set-desired-capacity \
        --region "$AWS_REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-capacity 2 >/dev/null || {
            echo "handover: ASG set-desired-capacity failed"
            return 1
        }

    echo "handover: waiting for standby to become STANDBY_READY (max ${STANDBY_WAIT_MAX_SECONDS}s)"
    local elapsed=0
    local state=""
    while [ "$elapsed" -lt "$STANDBY_WAIT_MAX_SECONDS" ]; do
        state="$(aws ssm get-parameter \
            --region "$AWS_REGION" \
            --name "$HANDOVER_STATE_PARAM" \
            --query "Parameter.Value" \
            --output text 2>/dev/null || echo "")"
        if [ "$state" = "STANDBY_READY" ]; then
            break
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    if [ "$state" != "STANDBY_READY" ]; then
        echo "handover: timeout waiting for standby (last state=$state)"
        return 1
    fi

    local standby_ip
    standby_ip="$(aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$STANDBY_IP_PARAM" \
        --query "Parameter.Value" \
        --output text 2>/dev/null || echo "")"
    if [ -z "$standby_ip" ] || [ "$standby_ip" = "None" ]; then
        echo "handover: standby ip is empty"
        return 1
    fi
    echo "handover: standby is ready at $standby_ip"

    # DuckDNS を新 IP へ切り替えるだけ。
    # 旧サーバー上のプレイヤーはこの後の AWS 強制 terminate（or 自分の self-terminate）で
    # 切断され、Reconnect ボタンを押せば DuckDNS 経由で新サーバーへ繋がる。
    # ServerTransferS2CPacket による自動再接続誘導はクライアント側 Netty 4.2 の
    # NPE レースで安定しなかったため撤去（mc-handover-mod の /transfer-all 呼び出しなし）。
    echo "handover: switching DuckDNS to standby ip $standby_ip"
    bash "$SCRIPT_DIR/update-dns.sh" --ip "$standby_ip" || {
        echo "handover: DuckDNS switch failed (will continue)"
    }

    mc_notify "🔄 新サーバー ($standby_ip) を起動しました。切断されたら Reconnect ボタンを押してください。"
    return 0
}

echo "spot-watch started; polling every ${POLL_INTERVAL}s"

while true; do
    TOKEN="$(imds_token || true)"

    # instance-action が存在すれば（HTTP 200）中断通知あり。404 なら通知なし。
    if [ -n "$TOKEN" ] && curl -sf \
        -H "X-aws-ec2-metadata-token: $TOKEN" \
        "$METADATA_URL" >/dev/null 2>&1; then
        echo "spot interruption notice detected; attempting handover"

        HANDOVER_OK=false
        if try_handover; then
            echo "handover succeeded"
            HANDOVER_OK=true
        else
            echo "handover failed; falling back to save-and-sync only"
            bash "$SCRIPT_DIR/save-and-sync.sh"
            mc_notify "⚠️ ハンドオーバーに失敗したため通常停止します（数分後に再接続してください）。"
        fi

        # 後始末: SSM の handover-state を IDLE に戻す（次回起動時に standby 扱いにならないよう）。
        aws ssm put-parameter \
            --region "$AWS_REGION" \
            --name "$HANDOVER_STATE_PARAM" \
            --value "IDLE" \
            --type String \
            --overwrite >/dev/null 2>&1 || true

        # ハンドオーバー成功時は ASG desired=2 のまま放置すると、自分が
        # AWS 側 PT2M で死んだ後に ASG が「2 台必要なのに 1 台しかない」と
        # 判断して余計なインスタンスを起動してしまう。
        # 自分自身を decrement 付き terminate して ASG を 1 台運用に戻す。
        # 失敗時は spot 強制終了が PT2M 内に来るので放置でも問題ないが、
        # 余計なインスタンスを生まないようこちらでも desired=1 にする。
        if [ "$HANDOVER_OK" = "true" ]; then
            SELF_TOKEN="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null || true)"
            SELF_INSTANCE_ID="$(curl -sf -H "X-aws-ec2-metadata-token: $SELF_TOKEN" \
                "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)"
            if [ -n "$SELF_INSTANCE_ID" ]; then
                echo "self-terminating $SELF_INSTANCE_ID with desired decrement"
                aws autoscaling terminate-instance-in-auto-scaling-group \
                    --region "$AWS_REGION" \
                    --instance-id "$SELF_INSTANCE_ID" \
                    --should-decrement-desired-capacity >/dev/null 2>&1 || \
                    echo "warn: self-terminate API failed; AWS will terminate via spot at PT2M"
            fi
        else
            # フォールバック側: desired を 1 に戻す（standby は要らない、AWS が自分を消す）
            aws autoscaling set-desired-capacity \
                --region "$AWS_REGION" \
                --auto-scaling-group-name "$ASG_NAME" \
                --desired-capacity 1 >/dev/null 2>&1 || true
        fi

        echo "spot-watch exiting"
        break
    fi

    sleep "$POLL_INTERVAL"
done
