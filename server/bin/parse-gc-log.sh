#!/bin/bash
#
# JVM の gc.log (text) を JSONL に変換し /var/log/minecraft-metrics/gc.jsonl に append する。
# flush-metrics.sh の rotate 前 hook から呼ばれる。
#
# 設計上の割り切り:
#   - active な /var/log/minecraft-metrics/gc.log のみ処理する
#   - JVM の filecount ローテーション (gc.log → gc.log.0..9) で生成された旧ファイルは無視する
#   - 結果として、rotate を跨ぐ瞬間の数百 KB 分 GC イベントは捨てる (許容範囲)
#
# この割り切りの理由:
#   ファイル名 (basename) ベースで offset 管理すると、rotate でファイル内容が入れ替わった際に
#   1) cur_size > offset なら新内容の先頭 offset バイトを欠損
#   2) cur_size < offset なら 0 から再処理し旧内容を二重投入
#   のどちらかが起きる。inode で管理する手もあるが、active file 限定の方が圧倒的にシンプル。
#   flush 間隔 5 分 vs gc.log filesize=20MB なら通常 1 サイクルで rotate を跨がない。
#
# 増分処理: /var/lib/minecraft-metrics/last-gc-offset.gc.log に処理済み byte offset を保存。
#   - cur_size < offset (= rotate された): offset を 0 にリセット
#   - cur_size == offset: 変化なし、skip
#   - cur_size > offset: 差分のみ parse。stat と tail のレース回避のため
#     `tail -c +N | head -c (cur_size - offset)` で読み込み量を厳密化する
#
# 対応フォーマット:
#   Generational ZGC (Java 25 のデフォルト、本リポジトリで採用):
#     [2026-06-28T08:51:30.456+0000][15.456s][info][gc] GC(0) Minor Collection (Metadata GC Threshold) 1234M(50%)->567M(20%) 12.345ms
#   G1 (フォールバック・参考):
#     [2026-06-28T08:51:30.456+0000][15.456s][info][gc] GC(0) Pause Young (Normal) (G1 Evacuation Pause) 1234M->567M(2048M) 12.345ms

set -uo pipefail

# shellcheck source=metrics-common.sh
source "$(dirname "$0")/metrics-common.sh"

f="$METRICS_LOG_DIR/gc.log"
[ -f "$f" ] || exit 0

offset_file="$METRICS_STATE_DIR/last-gc-offset.gc.log"
offset=$(cat "$offset_file" 2>/dev/null || echo 0)
cur_size=$(stat -c %s "$f" 2>/dev/null || echo 0)

if [ "$cur_size" -lt "$offset" ]; then
    # rotate でファイルが小さくなった → 新しい active gc.log として 0 から処理
    offset=0
elif [ "$cur_size" -eq "$offset" ]; then
    # 変化なし
    exit 0
fi

# stat 時点での読み込みバイト数 (この後 JVM が更に append しても今回サイクルでは取らない)
read_bytes=$((cur_size - offset))

TS_RE='^\[([0-9T:.+\-]+)\]'
ZGC_RE='GC\([0-9]+\)[[:space:]]+(Minor Collection|Major Collection|Garbage Collection)[[:space:]]+\(([^)]+)\)[[:space:]]+([0-9]+)M\([0-9]+%\)->([0-9]+)M\([0-9]+%\)[[:space:]]+([0-9.]+)(ms|s)'
G1_RE='GC\([0-9]+\)[[:space:]]+(Pause [A-Za-z ]+)[[:space:]]+\(([A-Za-z ]+)\)[[:space:]]+\(([^)]+)\)[[:space:]]+([0-9]+)M->([0-9]+)M\([0-9]+M\)[[:space:]]+([0-9.]+)ms'

if tail -c +$((offset + 1)) "$f" | head -c "$read_bytes" | {
    while IFS= read -r line; do
        [[ "$line" =~ $TS_RE ]] || continue
        iso="${BASH_REMATCH[1]}"
        ts=$(date -d "$iso" +%s 2>/dev/null) || continue

        if [[ "$line" =~ $ZGC_RE ]]; then
            event="${BASH_REMATCH[1]}"
            cause="${BASH_REMATCH[2]}"
            before="${BASH_REMATCH[3]}"
            after="${BASH_REMATCH[4]}"
            dur="${BASH_REMATCH[5]}"
            unit="${BASH_REMATCH[6]}"
            if [ "$unit" = "s" ]; then
                pause_ms=$(awk -v v="$dur" 'BEGIN{printf "%.3f", v*1000}')
            else
                pause_ms="$dur"
            fi
            printf '{"ts":"%s","event_type":"%s","before_heap_mb":%s,"after_heap_mb":%s,"pause_ms":%s,"cause":"%s"}\n' \
                "$ts" "$event" "$before" "$after" "$pause_ms" "$cause"
        elif [[ "$line" =~ $G1_RE ]]; then
            event="${BASH_REMATCH[1]}"
            sub="${BASH_REMATCH[2]}"
            cause="${BASH_REMATCH[3]}"
            before="${BASH_REMATCH[4]}"
            after="${BASH_REMATCH[5]}"
            pause_ms="${BASH_REMATCH[6]}"
            printf '{"ts":"%s","event_type":"%s (%s)","before_heap_mb":%s,"after_heap_mb":%s,"pause_ms":%s,"cause":"%s"}\n' \
                "$ts" "$event" "$sub" "$before" "$after" "$pause_ms" "$cause"
        fi
    done
} | metrics_append gc; then
    # 成功時は読み込んだ範囲の末尾を offset として保存
    echo "$((offset + read_bytes))" > "$offset_file"
else
    echo "warn: parse failed; retain offset"
fi
