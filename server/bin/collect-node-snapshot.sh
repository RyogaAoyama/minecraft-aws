#!/bin/bash
#
# ノード全体スナップショット collector (60s timer)。
# 旧 proc_stat / tps / spark_health の 3 テーブルを 1 テーブル (node_snapshot) に統合した実装。
#
# 1 サイクルで以下を集約し、1 JSONL 行を append:
#   /proc:  rss_kb, cpu_percent (前回 jiffies 差分), mem_avail_kb, load_1m
#   RCON:   players (list)
#   Spark:  tps_1m, mspt_1m, heap_used_mb (spark health --json)
#
# 設計:
#   - Spark mod 未ロード / クラッシュ時は Spark 由来 3 列のみ null。/proc 由来は publish 継続
#   - MC が起動していない場合は丸ごと skip (Spot 中断直後など)
#   - 状態 file: ${METRICS_STATE_DIR}/last-proc.state に "ts pid total_jiffies" を保存
#     pid 変化時 (MC 再起動) は cpu_percent=null

set -uo pipefail

# shellcheck source=/dev/null
source /etc/minecraft.env
# shellcheck source=mc-rcon.sh
source "$(dirname "$0")/mc-rcon.sh"
# shellcheck source=metrics-common.sh
source "$(dirname "$0")/metrics-common.sh"

ts=$(date +%s)
state_file="${METRICS_STATE_DIR}/last-proc.state"

# 1. Java プロセス特定
pid=$(pgrep -f "fabric-server-launch.jar" | head -1) || true
if [ -z "${pid:-}" ]; then
    # MC 未起動 (Spot 中断直後 / 起動前)。skip。
    exit 0
fi

# 2. /proc/<pid>/stat から jiffies (utime + stime)
if ! stat_line=$(cat /proc/"$pid"/stat 2>/dev/null); then
    echo "warn: /proc/$pid/stat unavailable; skip"
    exit 0
fi
utime=$(echo "$stat_line" | awk '{print $14}')
stime=$(echo "$stat_line" | awk '{print $15}')
total_jiffies=$((utime + stime))

# 3. /proc/<pid>/status から VmRSS
rss_kb=$(awk '/^VmRSS:/{print $2}' /proc/"$pid"/status 2>/dev/null || echo "")
# /proc/meminfo の MemAvailable
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
# /proc/loadavg の 1 分平均
load_1m=$(awk '{print $1}' /proc/loadavg)

# 4. cpu_percent: 前回 jiffies からの差分。初回 / pid 変化時は null
cpu_percent="null"
if [ -f "$state_file" ]; then
    prev_ts=""; prev_pid=""; prev_jiffies=""
    read -r prev_ts prev_pid prev_jiffies < "$state_file" || true
    if [ -n "$prev_ts" ] && [ "$pid" = "$prev_pid" ] && [ -n "$prev_jiffies" ]; then
        delta_jiffies=$((total_jiffies - prev_jiffies))
        delta_ts=$((ts - prev_ts))
        if [ "$delta_ts" -gt 0 ] && [ "$delta_jiffies" -ge 0 ]; then
            hz=$(getconf CLK_TCK)
            ncpu=$(nproc)
            cpu_percent=$(awk -v d="$delta_jiffies" -v t="$delta_ts" -v hz="$hz" -v n="$ncpu" \
                'BEGIN { printf "%.2f", (d / (hz * t * n)) * 100 }')
        fi
    fi
fi
echo "$ts $pid $total_jiffies" > "$state_file"

# 5. RCON list → players
players="null"
if list_out=$(mc_rcon list 2>/dev/null); then
    parsed=$(echo "$list_out" | grep -oE 'are [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$parsed" ]; then
        players="$parsed"
    fi
fi

# 6. RCON spark health --json → tps_1m / mspt_1m / heap_used_mb
# Spark mod 未ロード or 応答無しは 3 列 null のまま
tps_1m="null"
mspt_1m="null"
heap_used_mb="null"
if spark_out=$(mc_rcon "spark health --json" 2>/dev/null); then
    tps_val=$(echo "$spark_out" | jq -r '.tps."1m" // empty' 2>/dev/null || echo "")
    mspt_val=$(echo "$spark_out" | jq -r '.mspt."1m".mean // empty' 2>/dev/null || echo "")
    heap_bytes=$(echo "$spark_out" | jq -r '.memory.heap.used // empty' 2>/dev/null || echo "")
    [ -n "$tps_val" ] && tps_1m="$tps_val"
    [ -n "$mspt_val" ] && mspt_1m="$mspt_val"
    if [ -n "$heap_bytes" ]; then
        heap_used_mb=$(awk -v b="$heap_bytes" 'BEGIN { printf "%.0f", b / 1024 / 1024 }')
    fi
fi

# 7. JSONL 1 行 append
# 各値は数値 or 文字列 "null" のいずれか。JSON 上は null (識別子) として出力する。
printf '{"ts":"%s","rss_kb":%s,"cpu_percent":%s,"mem_avail_kb":%s,"load_1m":%s,"players":%s,"tps_1m":%s,"mspt_1m":%s,"heap_used_mb":%s}\n' \
    "$ts" "${rss_kb:-null}" "$cpu_percent" "${mem_avail_kb:-null}" "${load_1m:-null}" \
    "$players" "$tps_1m" "$mspt_1m" "$heap_used_mb" \
    | metrics_append node_snapshot
