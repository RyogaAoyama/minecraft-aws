#!/bin/bash
#
# ワールド資産を S3(真の保管庫) へ同期する。
#
# 手順:
#   1. RCON save-off       … 自動保存を止め、書き込み中ファイルの sync を避ける
#   2. RCON save-all flush  … 現在のワールドを確実にディスクへ書き出す
#   3. aws s3 sync          … ローカル → S3 へ差分同期（差分のみで転送量を小さく保つ）
#   4. RCON save-on        … 自動保存を再開
#
# RCON が使えない場合（サーバー停止中など）でも、ディスク上の現状を S3 へ同期する。
# これにより ExecStop（サーバープロセス終了後）からの呼び出しでも保存が成立する。
#
# world 破壊リスクへの対策:
#   - --delete は RCON save-all flush が成功した時（=ローカルが完全な状態）のみ付ける。
#     RCON 不通時は不完全なローカルで S3 を上書き/削除しないよう --delete なしで同期する。
#   - mods/ は CI が world/ に置く正本のため、マシンからの逆同期(ローカル→S3)では除外する。
#   - 反対に libraries/ と vanilla server.jar は launcher が自己DLする＝手動管理外なので、
#     S3 に永続化して次回起動時の外部再DL(server.jar ~150MB 等)を避け起動を高速化する。
#   - level.dat の存在を最低限ガードし、空/壊れたローカルで保管庫を上書きしない。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-rcon.sh
source "$(dirname "$0")/mc-rcon.sh"

# RCON でフラッシュ系コマンドを送る（サーバー稼働時のみ成功する）。
# サーバーが既に落ちている場合は失敗するが、その場合もディスクの現状を同期したいので
# エラーを致命としない。
function flush_world {
    mc_rcon save-off
    mc_rcon save-all flush
}

# 自動保存を再開する（flush_world が成功していた場合の対）。
function resume_world {
    mc_rcon save-on
}

echo "=== world-sync start ==="

# level.dat の存在を最低限ガード。1つも無い＝ワールド未取得/破損とみなし、
# 空/壊れたローカルで保管庫を上書きしないよう同期を中止する。
if ! find "$MC_DIR/server" -maxdepth 2 -name level.dat -print -quit | grep -q .; then
    echo "error: no level.dat found under $MC_DIR/server; aborting sync to protect S3 vault"
    exit 1
fi

# サーバー稼働中なら save-off + flush。落ちていれば現状のまま同期へ進む。
if flush_world; then
    RCON_HELD=1
else
    echo "warn: RCON flush skipped (server not responding); syncing disk state as-is"
    RCON_HELD=0
fi

# ローカル → S3 への差分同期。
#   - 除外: ログ類は保管庫に含めない。
#   - 除外: mods/ は CI が world/ に置く正本のため逆同期しない。
#   - 含める: libraries/ と vanilla server.jar は launcher が自己DLする手動管理外資産なので、
#            S3 に永続化して次回起動時の外部再DLを避ける（launcher は既存ファイルがあれば再DLをスキップ）。
# --delete は RCON flush 成功時のみ付与する（不完全ローカルでの S3 削除を避ける）。
DELETE_FLAG=()
if [ "$RCON_HELD" -eq 1 ]; then
    DELETE_FLAG=(--delete)
else
    echo "warn: syncing without --delete (RCON unavailable, local state may be incomplete)"
fi

aws s3 sync "$MC_DIR/server/" "s3://$WORLD_BUCKET/world/" \
    --region "$AWS_REGION" \
    "${DELETE_FLAG[@]}" \
    --exclude "logs/*" \
    --exclude "*.log" \
    --exclude "mods/*"

# save-off していた場合のみ save-on で戻す。
if [ "$RCON_HELD" -eq 1 ]; then
    resume_world || echo "warn: save-on failed (server may have stopped)"
fi

echo "=== world-sync complete ==="
