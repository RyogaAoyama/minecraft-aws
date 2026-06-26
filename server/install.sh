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

# 起動時間測定ログ（UserData と共有。CWAgent が /minecraft/startup-timing に転送）。
TIMING_LOG=/var/log/minecraft-startup-timing.log
log_phase() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) phase=$1" >> "$TIMING_LOG"; }
log_phase install-sh-start

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
log_phase step1-prepare-end

#######################################
# 2. 依存導入
#######################################
echo "=== [2/7] install dependencies ==="
# AMI に事前焼き込み済みなら dnf install / ソースビルドを skip する（カスタム AMI 採用時の起動時間短縮）。
# - Java 22 (Amazon Corretto, arm64 headless): c2me-fabric の c2me-opts-natives-math が Java 22 以上を要求するため
# - CloudWatch Agent: メトリクス転送
# - mcrcon: AL2023 リポジトリに無いため Tiiffi/mcrcon を gcc でソースビルド（バイナリは /usr/local/bin に配置）
PKGS_TO_INSTALL=()
command -v java >/dev/null 2>&1 \
    || PKGS_TO_INSTALL+=(java-22-amazon-corretto-headless)
[ -f /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ] \
    || PKGS_TO_INSTALL+=(amazon-cloudwatch-agent)
if [ "${#PKGS_TO_INSTALL[@]}" -gt 0 ]; then
    echo "installing: ${PKGS_TO_INSTALL[*]}"
    dnf install -y "${PKGS_TO_INSTALL[@]}"
else
    echo "java / cwagent are already present (likely pre-baked AMI); skip dnf install"
fi
if ! command -v mcrcon >/dev/null 2>&1; then
    echo "building mcrcon from source"
    dnf install -y gcc git
    BUILD_DIR="$(mktemp -d)"
    git clone --depth 1 https://github.com/Tiiffi/mcrcon.git "$BUILD_DIR/mcrcon"
    gcc -std=gnu11 -O2 -o /usr/local/bin/mcrcon "$BUILD_DIR/mcrcon/mcrcon.c"
    chmod +x /usr/local/bin/mcrcon
    rm -rf "$BUILD_DIR"
else
    echo "mcrcon already present; skip source build"
fi
log_phase step2-deps-end

# minecraft 専用ユーザーは作らず root 運用とする。
# 理由: インスタンスは使い捨て・単一用途で、外部公開はゲームポート(25565)のみ。
#       SSH も塞ぎ SSM 運用のため、権限分離より構成の単純さを優先する。

#######################################
# 3. ワールド資産取得
#######################################
echo "=== [3/7] sync world assets from S3 ==="
aws s3 sync "s3://$WORLD_BUCKET/world/" "$SERVER_DIR/" --region "$AWS_REGION"
log_phase step3-world-sync-end

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

# Tectonic（ワールド生成 MOD）の設定を配置。海と雪原の比率を抑えるチューニング。
# S3 同期で世界データと共に上書きされる前提だが、初回起動時にも参照されるようリポジトリ管理する。
mkdir -p "$SERVER_DIR/config"
cp "$CONFIG_SRC/tectonic.json" "$SERVER_DIR/config/tectonic.json"

# Structurify: 村の spacing を広げて密度を下げる（minecraft:villages の spacing/separation を上書き）。
cp "$CONFIG_SRC/structurify.json" "$SERVER_DIR/config/structurify.json"
log_phase step4-properties-end

#######################################
# 5. systemd ユニット配置 / MC を先に起動
#######################################
# Step 6 (CWAgent/DuckDNS/その他systemdユニット) を待たずに minecraft.service を起動する。
# MC のロード(数十秒)中に CWAgent/DuckDNS の数秒を裏で済ませることで、起動の合計時間を短縮する。
echo "=== [5/7] install systemd units and start minecraft.service (parallel to next step) ==="
cp "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now minecraft.service
log_phase step5-mc-launched

#######################################
# 6. CloudWatch Agent / DuckDNS / 監視ユニット (MC 起動と並列で実行)
#######################################
# MC 起動中の裏で実行するため、ここで失敗してもサーバー本体の起動を止めないこと。
echo "=== [6/7] configure CWAgent, update DuckDNS, enable watcher units (in parallel to MC boot) ==="
cp "$CONFIG_SRC/cwagent-config.json" \
    /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
log_phase step6a-cwagent-end

# DuckDNS 更新（リトライ・失敗時通知は update-dns.sh 側で実装）。
echo "update DuckDNS"
bash "$BIN_DIR/update-dns.sh" || true
log_phase step6b-dns-end

# 常駐監視 + 各タイマーは MC 起動完了前でも問題ないため、ここで並列に有効化する。
systemctl enable --now spot-watch.service
systemctl enable --now world-sync.timer
systemctl enable --now idle-check.timer
log_phase step6c-watchers-end

#######################################
# 7. 起動完了待ち / Discord 通知
#######################################
echo "=== [7/7] wait for server readiness and notify ==="
# 接続先は DuckDNS ドメインを使う。ドメイン名は SSM から取得する。
DUCKDNS_DOMAIN="$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$DUCKDNS_DOMAIN_SSM" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text)"
CONNECT_ADDRESS="${DUCKDNS_DOMAIN}"

# 起動完了は RCON 接続の成功で判定する。
# journalctl の "Done (" grep は、journald が起動直後の stdout をキャプチャし損ねる
# ケースがあり信頼できない。RCON で list が成功すれば接続受付可能。
# RCON パスワードは Step 4 で取得済みの $RCON_PASSWORD を再利用する。
READY=0
for _ in $(seq 1 180); do
    if MCRCON_PASS="$RCON_PASSWORD" mcrcon -H 127.0.0.1 -P "$RCON_PORT" list >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 5
done
log_phase step7-mc-ready

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

    # OP権限付与（プレイヤーがオフラインでも登録可能）。
    mc_rcon "op arar_arukun" || echo "warn: failed to op arar_arukun"
    echo "op privileges granted"

    # ゲームルール設定。
    mc_rcon "gamerule fall_damage false" || echo "warn: failed to set fall_damage"

    mc_notify "🟢 Minecraftサーバーが起動しました！ 接続先: ${CONNECT_ADDRESS}"
    echo "server ready; notified Discord"
else
    mc_notify "🟠 Minecraftサーバーの起動確認がタイムアウトしました（接続先候補: ${CONNECT_ADDRESS}）。ログを確認してください。"
    echo "warn: readiness check timed out"
fi

echo "=== install.sh complete ==="
