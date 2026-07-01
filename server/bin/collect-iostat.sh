#!/bin/bash
#
# ディスク I/O メトリクス collector。60s timer から呼ばれる。
#
# iostat -x -o JSON で nvme* デバイス (root EBS = nvme0n1 / NVMe ephemeral = nvme1n1) を抽出し、
# per-device で 1 行ずつ JSONL を /opt/minecraft/server/metrics/iostat.jsonl に append する。
#
# 設計:
#   - iostat 自身の interval を 1s × 1 回にしてサンプルを取得 (jiffies 差分ベース)
#     timer 側の 60s 間隔がサンプル粒度
#   - sysstat の version 差で "rkB/s" vs "rsec/s" の違いがあるが AL2023 同梱版は kB/s 系で固定
#   - jq の bracket 記法 .["r/s"] は "/" を含むキー名に必須

# 観測の失敗で他 collector や本体に波及させないため set -e は使わない
set -uo pipefail

# shellcheck source=metrics-common.sh
source "$(dirname "$0")/metrics-common.sh"

ts=$(date +%s)

# iostat -x: 拡張統計 / -o JSON: JSON 出力 / 1 1: 1 秒インターバル 1 回
iostat_json=$(iostat -x -o JSON 1 1 2>/dev/null) || {
    echo "warn: iostat failed; skip"
    exit 0
}

# nvme* のみを per-row JSONL 化。null/欠損キーは出力 JSON でも null になる (Athena 側 nullable で受ける)
echo "$iostat_json" | jq -c --arg ts "$ts" '
    .sysstat.hosts[0].statistics[0].disk[]
    | select(.disk_device | test("^nvme"))
    | {
        ts: $ts,
        dev: .disk_device,
        r_iops: .["r/s"],
        w_iops: .["w/s"],
        r_kbps: .["rkB/s"],
        w_kbps: .["wkB/s"],
        r_await: .["r_await"],
        w_await: .["w_await"],
        queue: .["aqu-sz"],
        util: .["%util"]
      }
' | metrics_append iostat
