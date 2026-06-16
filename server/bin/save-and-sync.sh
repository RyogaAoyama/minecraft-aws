#!/bin/bash
#
# 保存 + S3同期の共通エントリポイント。
# ExecStop（サーバー停止）・spot中断・アイドル終了の複数経路から呼ばれるため、
# flock で多重実行をガードし、s3 sync の衝突を防ぐ。
#
# 例: アイドル終了の terminate と spot-watch が同時に save を試みても、
#     2つ目は1つ目の完了を待ってから（=ほぼ何もせず差分0で）流れる。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env

LOCK_FILE="/run/minecraft-save.lock"
SCRIPT_DIR="$(dirname "$0")"

# 既に save 中なら最大 110 秒待ってロックを取得する（スポット中断の2分猶予内）。
# タイムアウトした場合でも sync は走らせる（落ちる前に1回でも保存を試みる）。
exec 9>"$LOCK_FILE"
flock -w 110 9 || echo "warn: could not acquire save lock in time; proceeding anyway"

bash "$SCRIPT_DIR/world-sync.sh"
