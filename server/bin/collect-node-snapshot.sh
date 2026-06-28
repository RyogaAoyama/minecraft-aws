#!/bin/bash
#
# ノード全体スナップショット collector (60s timer)。
#
# 1 サイクルで以下を集約し、1 JSONL 行を append:
#   /proc:  rss_kb, cpu_percent (前回 jiffies 差分), mem_avail_kb, load_1m
#   RCON:   players (list)
#   jcmd:   heap_used_mb (GC.heap_info)
#
# 設計:
#   - heap_used_mb は jcmd GC.heap_info から ZGC の used 値をパースして取得。
#     jcmd が応答しない / 未起動時は null のまま publish 継続。
#   - 旧版で取っていた tps_1m / mspt_1m は spark mod の RCON 連携が
#     Fabric 環境では機能しない (lucko/spark#119) ため撤去。同等の値を
#     RCON 経由で安定して取得する手段は現状無いと判断。
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

# 6. jcmd GC.heap_info → heap_used_mb
# ZGC の出力例 (Java 25):
#   ZHeap           used 532M, capacity 6144M, max 6144M
# G1 等の他 GC でも "used XXXM" 形式が共通なので、最初に出てくる
# "used <数値><単位>" を拾う。M/G は MiB/GiB として扱う。
heap_used_mb="null"
if heap_out=$(jcmd "$pid" GC.heap_info 2>/dev/null); then
    if [[ "$heap_out" =~ used[[:space:]]+([0-9]+)([KMG]) ]]; then
        v="${BASH_REMATCH[1]}"
        u="${BASH_REMATCH[2]}"
        case "$u" in
            K) heap_used_mb=$(awk -v v="$v" 'BEGIN { printf "%.0f", v / 1024 }') ;;
            M) heap_used_mb="$v" ;;
            G) heap_used_mb=$(awk -v v="$v" 'BEGIN { printf "%.0f", v * 1024 }') ;;
        esac
    fi
fi

# 7. JSONL 1 行 append
# 各値は数値 or 文字列 "null" のいずれか。JSON 上は null (識別子) として出力する。
printf '{"ts":"%s","rss_kb":%s,"cpu_percent":%s,"mem_avail_kb":%s,"load_1m":%s,"players":%s,"heap_used_mb":%s}\n' \
    "$ts" "${rss_kb:-null}" "$cpu_percent" "${mem_avail_kb:-null}" "${load_1m:-null}" \
    "$players" "$heap_used_mb" \
    | metrics_append node_snapshot
