#!/bin/bash

set -euo pipefail

### Minecraft on AWS: リポジトリの server/ を worldバケットの bootstrap/ へ同期する ###
### インスタンス起動時に UserData / install.sh がここから管理スクリプトを取得する。 ###
###                                                                                  ###
### 注意: S3 はファイルの実行権限(パーミッション)をメタデータとして保持しない。     ###
###       そのため、ダウンロード側（インスタンスの install.sh）で *.sh に対し        ###
###       明示的に chmod +x を行う前提とする。本スクリプトでは権限同期はしない。     ###

# ヘルプ
function usage {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
    -h          ヘルプ
    -p profile  [必須]AWS CLIのプロファイル。
EOM
    exit 2
}

# オプション変数の初期値
PROFILE=""

# オプション解析
while getopts p:h OPT; do
    case $OPT in
    p) PROFILE=${OPTARG} ;;
    h | \?) usage ;;
    esac
done

# バリデーション
if [ -z "${PROFILE}" ]; then
    echo "error->This value is required->-p"
    usage
fi

# リージョン（プロジェクト共通: 東京）
AWS_REGION="ap-northeast-1"

# 同期元/同期先（固定）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/../server"
DEST_URI="s3://minecraft-world-prd/bootstrap/"

# 同期元の存在チェック
if [ ! -d "${SOURCE_DIR}" ]; then
    echo "error->source dir not found->${SOURCE_DIR}"
    exit 1
fi

echo "=== Sync bootstrap start ==="
echo "  source: ${SOURCE_DIR}"
echo "  dest  : ${DEST_URI}"

# --delete で source 側に無いオブジェクトを bootstrap/ から除去し、完全ミラーにする
aws --profile "${PROFILE}" --region "${AWS_REGION}" s3 sync \
    "${SOURCE_DIR}/" "${DEST_URI}" \
    --delete

echo "=== Sync bootstrap complete ==="
