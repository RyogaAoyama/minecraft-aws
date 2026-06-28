#!/bin/bash
#
# 観測メトリクス collector の共通関数。各 collector が `source` して使う。
#
# 役割:
#   - JSONL の追記先ディレクトリ・state ディレクトリの定義
#   - per-kind flock 経由の append (flush-metrics.sh の rotate と race しないよう同期する)
#
# 設計原則:
#   - collector 1 サイクルでの append は 1 行のみ (multi-row な iostat 等は事前に
#     まとめて 1 回の cat に渡す)
#   - lock 保持時間は最小化 (cat の所要時間のみ。秒未満)

METRICS_LOG_DIR=/var/log/minecraft-metrics
METRICS_STATE_DIR=/var/lib/minecraft-metrics

# 標準入力から受け取った内容を ${METRICS_LOG_DIR}/<kind>.jsonl に追記する。
# flush-metrics.sh が同名 lock を取って mv するため、append は subshell + flock で同期する。
#
# 引数: $1  kind (iostat / node_snapshot / gc / save_sync / startup)
# 標準入力: 追記する JSONL (改行込み)
function metrics_append {
    local kind="$1"
    local lock_file="/run/minecraft-metrics-${kind}.lock"
    local out_file="${METRICS_LOG_DIR}/${kind}.jsonl"
    (
        flock 9
        cat >> "$out_file"
    ) 9>"$lock_file"
}
