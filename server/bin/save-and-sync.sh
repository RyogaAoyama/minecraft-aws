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

# 既に save 中なら最大 60 秒待ってロックを取得する。
# TimeoutStopSec=110 内で minecraft.service の ExecStop 連鎖 (save-and-sync.sh →
# flush-metrics.sh) を完了させるため、save 側の待ち時間を 60s に圧縮し、
# flush-metrics.sh に最低 50s を残す。タイムアウトしても sync は走らせる。
exec 9>"$LOCK_FILE"
flock -w 60 9 || echo "warn: could not acquire save lock in time; proceeding anyway"

bash "$SCRIPT_DIR/world-sync.sh"
