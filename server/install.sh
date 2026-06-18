#!/bin/bash
#
# Minecraft サーバーのセットアップ本体。UserData から `bash /opt/minecraft/bootstrap/install.sh` で呼ばれる。
#
# 配置について:
#   sync-bootstrap.sh が リポジトリの server/ を s3://<world>/bootstrap/ へ同期し、
#   UserData が bootstrap/ を /opt/minecraft/bootstrap/ へ s3 sync で展開する。
#   s3 sync はディレクトリ階層を保持するため、展開後の「ブートストラップ展開ルート」は:
#       /opt/minecraft/bootstrap/install.sh      (このファイル。server/ 直下に置く)
#       /opt/minecraft/bootstrap/bin/*.sh        (server/bin/ 由来の管理スクリプト)
#       /opt/minecraft/bootstrap/systemd/*       (server/systemd/ 由来のユニット)
#       /opt/minecraft/bootstrap/config/*        (server/config/ 由来の設定)
#   となる。
#
# 本スクリプトの責務は、この展開ルートから実行時レイアウトへ配置すること:
#   - bin/*.sh   → /opt/minecraft/bin/        （単一bin。コピー + chmod +x）
#   - systemd/*  → /etc/systemd/system/
#   - config/*   → server.properties 生成・eula 配置・CWAgent 設定配置
# systemd ユニットの ExecStart/ExecStop は単一bin /opt/minecraft/bin/*.sh を指す。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env

# このスクリプトが置かれたブートストラップ展開ルート（=/opt/minecraft/bootstrap）。
BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$BOOTSTRAP_DIR/bin"
SYSTEMD_SRC="$BOOTSTRAP_DIR/systemd"
CONFIG_SRC="$BOOTSTRAP_DIR/config"
# 管理スクリプトの実行時配置先（単一bin）。
BIN_DIR="$MC_DIR/bin"
SERVER_DIR="$MC_DIR/server"

# 通知ラッパは展開ルート側(BIN_SRC)から読み込む（配置前でも起動失敗通知できるように）。
# shellcheck source=server/bin/mc-notify.sh
source "$BIN_SRC/mc-notify.sh"

#######################################
# 1. ディレクトリ作成 / 実行権付与
#######################################
echo "=== [1/7] prepare directories and deploy management scripts ==="
mkdir -p "$SERVER_DIR" "$BIN_DIR" /var/lib/minecraft
# 展開ルートの bin/*.sh を単一bin(/opt/minecraft/bin)へコピーし、実行権を付与する
# （S3は実行権限を保持しないため、配置後に chmod +x する）。
cp "$BIN_SRC"/*.sh "$BIN_DIR/"
chmod +x "$BIN_DIR"/*.sh

#######################################
# 2. 依存導入
#######################################
echo "=== [2/7] install dependencies ==="
# Java 21 (Amazon Corretto, arm64 headless)
dnf install -y java-21-amazon-corretto-headless
# CloudWatch Agent
dnf install -y amazon-cloudwatch-agent
# mcrcon は AL2023 のリポジトリに無いため、軽量な C 実装(Tiiffi/mcrcon)をソースビルドする。
# 依存は gcc のみ。ビルド済みバイナリは /usr/local/bin に置き PATH を通す。
if ! command -v mcrcon >/dev/null 2>&1; then
    echo "building mcrcon from source"
    dnf install -y gcc git
    BUILD_DIR="$(mktemp -d)"
    git clone --depth 1 https://github.com/Tiiffi/mcrcon.git "$BUILD_DIR/mcrcon"
    gcc -std=gnu11 -O2 -o /usr/local/bin/mcrcon "$BUILD_DIR/mcrcon/mcrcon.c"
    chmod +x /usr/local/bin/mcrcon
    rm -rf "$BUILD_DIR"
fi

# minecraft 専用ユーザーは作らず root 運用とする。
# 理由: インスタンスは使い捨て・単一用途で、外部公開はゲームポート(25565)のみ。
#       SSH も塞ぎ SSM 運用のため、権限分離より構成の単純さを優先する。

#######################################
# 3. ワールド資産取得
#######################################
echo "=== [3/7] sync world assets from S3 ==="
aws s3 sync "s3://$WORLD_BUCKET/world/" "$SERVER_DIR/" --region "$AWS_REGION"

#######################################
# 4. server.properties / eula.txt 生成
#######################################
echo "=== [4/7] generate server.properties / eula.txt ==="
# RCON パスワードを SSM から取得し、テンプレのプレースホルダを置換する。
# パスワードはファイル(server.properties)に書き込まれるが、これは Minecraft の仕様上必須。
# server.properties は外部公開されないローカルファイルであり、リポジトリにはコミットしない。
RCON_PASSWORD="$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$RCON_PASSWORD_SSM" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text)"

# テンプレ内の __RCON_PASSWORD__ / __RCON_PORT__ を実値へ置換して配置。
sed -e "s|__RCON_PASSWORD__|${RCON_PASSWORD}|g" \
    -e "s|__RCON_PORT__|${RCON_PORT}|g" \
    "$CONFIG_SRC/server.properties.tmpl" > "$SERVER_DIR/server.properties"
chmod 600 "$SERVER_DIR/server.properties"

cp "$CONFIG_SRC/eula.txt" "$SERVER_DIR/eula.txt"

#######################################
# 5. CloudWatch Agent 設定配置 / 起動
#######################################
echo "=== [5/7] configure and start CloudWatch Agent ==="
cp "$CONFIG_SRC/cwagent-config.json" \
    /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# DuckDNS 更新（リトライ・失敗時通知は update-dns.sh 側で実装）。
# DNS 更新失敗は Webhook 通知で可視化済みなので、ここで止めずサーバー本体の起動は継続する
# （set -e 下で失敗すると systemd 配置・MC 起動に到達しなくなるのを避ける）。
echo "update DuckDNS"
bash "$BIN_DIR/update-dns.sh" || true

#######################################
# 6. systemd ユニット配置 / 有効化
#######################################
echo "=== [6/7] install and enable systemd units ==="
cp "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.timer /etc/systemd/system/
systemctl daemon-reload

# 本体サービス + 常駐監視 + 各タイマーを有効化・起動。
systemctl enable --now minecraft.service
systemctl enable --now spot-watch.service
systemctl enable --now world-sync.timer
systemctl enable --now idle-check.timer

#######################################
# 7. 起動完了待ち / Discord 通知
#######################################
echo "=== [7/7] wait for server readiness and notify ==="
# 接続先は DuckDNS ドメインを使う。ドメイン名は SSM から取得する。
DUCKDNS_DOMAIN="$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$DUCKDNS_DOMAIN_SSM" \
    --query "Parameter.Value" \
    --output text)"
CONNECT_ADDRESS="${DUCKDNS_DOMAIN}.duckdns.org"

# 起動完了は「接続受付可能になった正式な合図」＝サーバーログの `Done (` 出力で判定する。
# Minecraft サーバーは起動完了時に `Done (X.Xs)! For help, type "help"` を標準出力へ出し、
# Type=simple の systemd ユニット配下では journald に記録される。
# RCON list 応答よりこちらの方が正式な「接続受付可能」の合図であり、初回の重い起動
# （libraries 再DL + ワールドロード）でも取りこぼさないよう待ち時間を十分に延ばす（5秒×180回＝約15分）。
# 注: `set -euo pipefail` 下で journalctl|grep の grep 不一致(exit 1)がスクリプトを落とさないよう、
#     判定は if 条件として扱う（不一致時はそのまま次ループへ進む）。
READY=0
for _ in $(seq 1 180); do
    if journalctl -u minecraft.service --no-pager 2>/dev/null | grep -q "Done ("; then
        READY=1
        break
    fi
    sleep 5
done

if [ "$READY" -eq 1 ]; then
    # shellcheck source=server/bin/mc-rcon.sh
    source "$BIN_DIR/mc-rcon.sh"

    # ホワイトリスト登録（config/whitelist-players.txt に記載されたプレイヤーを自動追加）。
    # サーバーが online-mode=true で稼働中のため、whitelist add が Mojang API で UUID を解決する。
    WHITELIST_FILE="$CONFIG_SRC/whitelist-players.txt"
    if [ -f "$WHITELIST_FILE" ]; then
        while IFS= read -r player || [ -n "$player" ]; do
            [ -z "$player" ] && continue
            mc_rcon "whitelist add $player" || echo "warn: failed to whitelist $player"
        done < "$WHITELIST_FILE"
        echo "whitelist players registered"
    fi

    mc_notify "🟢 Minecraftサーバーが起動しました！ 接続先: ${CONNECT_ADDRESS}:25565"
    echo "server ready; notified Discord"
else
    mc_notify "🟠 Minecraftサーバーの起動確認がタイムアウトしました（接続先候補: ${CONNECT_ADDRESS}:25565）。ログを確認してください。"
    echo "warn: readiness check timed out"
fi

echo "=== install.sh complete ==="
