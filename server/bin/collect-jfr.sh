#!/bin/bash
#
# JFR (Java Flight Recorder) スナップショットから GC イベントを抽出し
# /var/log/minecraft-metrics/gc.jsonl に append する。60s timer から呼ばれる。
#
# JVM 側 (minecraft.service) で以下の継続録画が動いている前提:
#   -XX:StartFlightRecording=name=mc,filename=/var/log/minecraft-metrics/mc.jfr,
#       disk=true,maxage=10m,maxsize=100M,settings=default
#
# 1 サイクルの流れ:
#   1) jcmd $pid JFR.dump name=mc filename=$snapshot で snapshot.jfr を上書き
#      (継続録画自体は止まらない)。
#   2) jfr print --json --events jdk.GarbageCollection,jdk.GCHeapSummary で JSON 取得。
#   3) jq で GarbageCollection を主、GCHeapSummary (when=Before/After GC) を gcId で
#      join し、1 GC = 1 行の JSONL を作る。
#   4) 前回処理した最終 startTime より後のイベントだけ emit (重複排除)。
#   5) 今回 snapshot 内の最大 startTime を last-jfr-ts に保存し次回の起点にする。
#
# 旧 parse-gc-log.sh (gc.log を正規表現で抽出) を置換するもの。JFR は JDK 公式 ABI
# なのでログフォーマット揺れとイベント取りこぼしの両方を排除できる。
#
# 観測の失敗で他 collector や本体に波及させないため set -e は使わない。

set -uo pipefail

# shellcheck source=metrics-common.sh
source "$(dirname "$0")/metrics-common.sh"

pid=$(pgrep -f "fabric-server-launch.jar" | head -1) || true
if [ -z "${pid:-}" ]; then
    # MC 未起動 (Spot 中断直後 / 起動前)。skip。
    exit 0
fi

snapshot="${METRICS_STATE_DIR}/snapshot.jfr"
last_ts_file="${METRICS_STATE_DIR}/last-jfr-ts"
last_ts=$(cat "$last_ts_file" 2>/dev/null || echo "0")

# 継続録画 "mc" のスナップショットを snapshot.jfr に書き出す (上書き)。
if ! jcmd "$pid" JFR.dump name=mc filename="$snapshot" >/dev/null 2>&1; then
    echo "warn: JFR.dump failed; skip"
    exit 0
fi

# JFR JSON の startTime / duration は JDK 版や設定でフォーマットが揺れるため、
# 数値秒・ISO 8601 timestamp・ISO 8601 duration (PT…S) のいずれも吸収する。
# - startTime: ISO ("2026-06-28T01:30:45.123456789Z") か epoch ns (number)
# - duration:  ISO duration ("PT0.012345S") か秒の number
JQ_PROG=$(cat <<'JQ'
def to_unix:
    if type == "number" then (. / 1000000000 | floor | tostring)
    else (split(".")[0] | split("Z")[0] | split("+")[0]
          | strptime("%Y-%m-%dT%H:%M:%S") | mktime | tostring)
    end;
def dur_ms:
    if type == "number" then (. * 1000)
    elif (type == "string" and test("^PT")) then
        (sub("^PT"; "") | sub("S$"; "") | tonumber * 1000)
    else (tonumber * 1000)
    end;
[.recording.events[]] as $events
| ($events | map(select(.type == "jdk.GarbageCollection"))) as $gcs
| ($events | map(select(.type == "jdk.GCHeapSummary"))) as $heaps
| $gcs[]
| .values as $gc
| (($heaps | map(select(.values.gcId == $gc.gcId and .values.when == "Before GC"))) | first) as $hb
| (($heaps | map(select(.values.gcId == $gc.gcId and .values.when == "After GC"))) | first) as $ha
| ($gc.startTime | tostring) as $st
| select($st > $last)
| {
    ts: ($gc.startTime | to_unix),
    start_time: $st,
    gc_id: $gc.gcId,
    name: ($gc.name // ""),
    cause: ($gc.cause // ""),
    duration_ms: ($gc.duration | dur_ms),
    heap_before_mb: (($hb.values.heapUsed // 0) / 1024 / 1024 | floor),
    heap_after_mb:  (($ha.values.heapUsed // 0) / 1024 / 1024 | floor)
}
JQ
)

jfr_json=$(jfr print --json --events jdk.GarbageCollection,jdk.GCHeapSummary "$snapshot" 2>/dev/null) || {
    echo "warn: jfr print failed; skip"
    exit 0
}

echo "$jfr_json" | jq -c --arg last "$last_ts" "$JQ_PROG" | metrics_append gc

# 今回の snapshot 内最大 startTime を次回起点として保存。
# emit の有無に関わらず snapshot 内最大値で進める (= 同じイベントを 2 度 emit しない)。
max_st=$(echo "$jfr_json" \
    | jq -r '[.recording.events[] | select(.type == "jdk.GarbageCollection") | .values.startTime | tostring] | max // empty')
if [ -n "$max_st" ]; then
    echo "$max_st" > "$last_ts_file"
fi
