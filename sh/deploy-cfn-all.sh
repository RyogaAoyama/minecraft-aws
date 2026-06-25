#!/bin/bash

### Minecraft on AWS: CloudFormationを依存順に並列デプロイするスクリプト ###
### deploy-cfn.sh をラップし、以下の依存グラフで実行する:                   ###
###   Phase0: SSM Parameter `/minecraft/prd/ami-id` を AL2023 標準で初期化  ###
###          (既存なら何もしない。Image Builder のパイプライン完了で上書きされる) ###
###   Phase1: net                                                          ###
###   Phase2: sec, rec, img    (並列 / net 依存)                           ###
###   Phase3: ins             (net/sec/rec/img 依存)                       ###
###   Phase4: mon, fnc        (並列 / rec/ins/sec 依存)                    ###

set -euo pipefail

# ヘルプ
function usage {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
    -h          ヘルプ
    -e prd      [必須]デプロイする環境。prd のみ対応。
    -p profile  [必須]AWS CLIのプロファイル。
EOM
    exit 2
}

# オプション変数の初期値
ENV=""
PROFILE=""

# オプション解析
while getopts e:p:h OPT; do
    case $OPT in
    e) ENV=${OPTARG} ;;
    p) PROFILE=${OPTARG} ;;
    h | \?) usage ;;
    esac
done

# バリデーション
if [ -z "${ENV}" ] || [ -z "${PROFILE}" ]; then
    echo "error->Required options: -e, -p"
    usage
fi

if [ "${ENV}" != "prd" ]; then
    echo "error->Env not supported->${ENV}（prd のみ対応）"
    exit 1
fi

# リージョン（プロジェクト共通: 東京）
AWS_REGION="ap-northeast-1"

# デプロイ用S3バケット（固定・単一・要事前作成）
DEPLOY_BUCKET="minecraft-deploy-prd"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 割り込み/失敗時にバックグラウンドプロセスを停止
cleanup() {
    echo "Caught signal, stopping background processes..."
    # shellcheck disable=SC2046
    kill $(jobs -p) 2>/dev/null || true
    wait 2>/dev/null || true
    exit 1
}
trap cleanup SIGINT SIGTERM

# 前提チェック: deploy バケットが存在しないと cloudformation package が失敗するため先に検証する
echo "=== Pre-check: deploy bucket '${DEPLOY_BUCKET}' ==="
if ! aws --profile "${PROFILE}" --region "${AWS_REGION}" s3api head-bucket --bucket "${DEPLOY_BUCKET}" 2>/dev/null; then
    echo "error->deploy bucket '${DEPLOY_BUCKET}' が存在しません（または権限がありません）。"
    echo "        'cloudformation package' の前提となるため、先にバケットを作成してください。"
    echo "        例: aws --profile ${PROFILE} --region ${AWS_REGION} s3api create-bucket \\"
    echo "              --bucket ${DEPLOY_BUCKET} \\"
    echo "              --create-bucket-configuration LocationConstraint=${AWS_REGION}"
    exit 1
fi
echo "=== Pre-check OK ==="

# Phase 0: Instance.yml が AmiId として参照する SSM Parameter を必ず存在させる。
# 既存なら値は保持（Image Builder のパイプライン完了で書き込まれた最新値を保護）。
# ただし DataType は aws:ec2:image でなければならない（Image Builder の DistributionConfiguration
# が DataType: aws:ec2:image でしか書き込めないため）。text タイプで残っている場合は
# 既存値を保ったまま delete-parameter → put-parameter で再作成する。
echo "--- Phase 0: ensure SSM Parameter /minecraft/prd/ami-id (DataType: aws:ec2:image) ---"
EXISTING_DATA_TYPE="$(aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm get-parameter \
    --name /minecraft/prd/ami-id --query 'Parameter.DataType' --output text 2>/dev/null || true)"
case "${EXISTING_DATA_TYPE}" in
"aws:ec2:image")
    echo "  /minecraft/prd/ami-id already exists with correct DataType; keep as is"
    ;;
"")
    BASE_AMI="$(aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm get-parameter \
        --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
        --query 'Parameter.Value' --output text)"
    aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm put-parameter \
        --name /minecraft/prd/ami-id \
        --value "${BASE_AMI}" \
        --type String \
        --data-type aws:ec2:image \
        --description "Pre-baked AMI for minecraft. Initialized from AL2023 standard. Updated by Image Builder pipeline." \
        >/dev/null
    echo "  initialized /minecraft/prd/ami-id = ${BASE_AMI}"
    ;;
*)
    echo "  /minecraft/prd/ami-id exists with DataType=${EXISTING_DATA_TYPE}, recreating as aws:ec2:image"
    CURRENT_VALUE="$(aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm get-parameter \
        --name /minecraft/prd/ami-id --query 'Parameter.Value' --output text)"
    aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm delete-parameter \
        --name /minecraft/prd/ami-id >/dev/null
    aws --profile "${PROFILE}" --region "${AWS_REGION}" ssm put-parameter \
        --name /minecraft/prd/ami-id \
        --value "${CURRENT_VALUE}" \
        --type String \
        --data-type aws:ec2:image \
        --description "Pre-baked AMI for minecraft. Recreated with DataType=aws:ec2:image. Updated by Image Builder pipeline." \
        >/dev/null
    echo "  recreated /minecraft/prd/ami-id = ${CURRENT_VALUE}"
    ;;
esac
echo "--- Phase 0 complete ---"

echo "=== CloudFormation parallel deploy start ==="

# Phase 1: net（基盤VPC。以降の全スタックが依存）
echo "--- Phase 1: Network ---"
"${SCRIPT_DIR}/deploy-cfn.sh" -c net -e "${ENV}" -p "${PROFILE}"
echo "--- Phase 1 complete ---"

# Phase 2: sec / rec / img を並列実行（いずれも net に依存）
echo "--- Phase 2: Security + Resource + Image (parallel) ---"

"${SCRIPT_DIR}/deploy-cfn.sh" -c sec -e "${ENV}" -p "${PROFILE}" &
PID_SEC=$!

"${SCRIPT_DIR}/deploy-cfn.sh" -c rec -e "${ENV}" -p "${PROFILE}" &
PID_REC=$!

"${SCRIPT_DIR}/deploy-cfn.sh" -c img -e "${ENV}" -p "${PROFILE}" &
PID_IMG=$!

FAILED=0
wait ${PID_SEC} || FAILED=1
if [ ${FAILED} -ne 0 ]; then
    echo "error->Security stack deploy failed"
    kill ${PID_REC} ${PID_IMG} 2>/dev/null || true
    wait ${PID_REC} ${PID_IMG} 2>/dev/null || true
    exit 1
fi

wait ${PID_REC} || FAILED=1
if [ ${FAILED} -ne 0 ]; then
    echo "error->Resource stack deploy failed"
    kill ${PID_IMG} 2>/dev/null || true
    wait ${PID_IMG} 2>/dev/null || true
    exit 1
fi

wait ${PID_IMG} || FAILED=1
if [ ${FAILED} -ne 0 ]; then
    echo "error->Image stack deploy failed"
    exit 1
fi
echo "--- Phase 2 complete ---"

# Phase 3: ins（net/sec/rec に依存）
echo "--- Phase 3: Instance ---"
"${SCRIPT_DIR}/deploy-cfn.sh" -c ins -e "${ENV}" -p "${PROFILE}"
echo "--- Phase 3 complete ---"

# Phase 4: mon と fnc を並列実行（rec/ins/sec に依存）
echo "--- Phase 4: Monitoring + Function (parallel) ---"

"${SCRIPT_DIR}/deploy-cfn.sh" -c mon -e "${ENV}" -p "${PROFILE}" &
PID_MON=$!

"${SCRIPT_DIR}/deploy-cfn.sh" -c fnc -e "${ENV}" -p "${PROFILE}" &
PID_FNC=$!

FAILED=0
wait ${PID_MON} || FAILED=1
if [ ${FAILED} -ne 0 ]; then
    echo "error->Monitoring stack deploy failed"
    kill ${PID_FNC} 2>/dev/null || true
    wait ${PID_FNC} 2>/dev/null || true
    exit 1
fi

wait ${PID_FNC} || FAILED=1
if [ ${FAILED} -ne 0 ]; then
    echo "error->Function stack deploy failed"
    exit 1
fi
echo "--- Phase 4 complete ---"

echo "=== CloudFormation parallel deploy complete ==="
