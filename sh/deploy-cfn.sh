#!/bin/bash

set -euo pipefail

### Minecraft on AWS: CloudFormationを1スタックずつデプロイするスクリプト ###
### cmsv2 の deploy-cfn.sh をベースに、Minecraftプロジェクト用へ改変。     ###
###   - 命名は minecraft-{type}-prd（ServiceName無し / Env=prd固定）        ###
###   - デプロイ用バケットは minecraft-deploy-prd（単一・要事前作成）       ###

# ヘルプ
function usage {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
    -h          ヘルプ
    -c type     [必須]デプロイするCfnの種別。net|sec|rec|img|ins|mon|fnc|ana に対応。
    -e prd      [必須]デプロイする環境。prd のみ対応（その他はエラー）。
    -p profile  [必須]AWS CLIのプロファイル。
EOM
    exit 2
}

# オプション変数の初期値
CFN=""
ENV=""
PROFILE=""

# オプション解析
while getopts c:e:p:h OPT; do
    case $OPT in
    c)
        CFN=${OPTARG}
        ;;
    e)
        if [ "${OPTARG}" = "prd" ]; then
            ENV=${OPTARG}
        else
            echo "error->env not supported->${OPTARG}（prd のみ対応）"
            exit 1
        fi
        ;;
    p)
        PROFILE=${OPTARG}
        ;;
    h | \?)
        usage
        ;;
    esac
done

# バリデーション
if [ "${PROFILE}" = "" ]; then
    echo "error->This value is required->-p"
    usage
fi

if [ "${CFN}" = "" ]; then
    echo "error->This value is required->-c"
    usage
fi

if [ "${ENV}" = "" ]; then
    echo "error->This value is required->-e"
    usage
fi

# リージョン（プロジェクト共通: 東京）
AWS_REGION="ap-northeast-1"

# デプロイ用S3バケット（固定・単一・要事前作成）
S3_BUCKET_NAME="minecraft-deploy-prd"

# package 後のテンプレ出力先（プロセスIDで一意化）
DEPLOY_FILE="./../cloudformation-${CFN}-$$"

# 環境変数をインポート（PRODUCT_NAME=minecraft）
. ./cloudformation/config/parameters.txt

# デプロイするCfnファイルとスタック名を設定
TEMPLATE_PATH=""
STACK_NAME=""
case "${CFN}" in
net)
    TEMPLATE_PATH='./cloudformation/Network.yml'
    STACK_NAME="${PRODUCT_NAME}-net-${ENV}"
    ;;
sec)
    TEMPLATE_PATH='./cloudformation/Security.yml'
    STACK_NAME="${PRODUCT_NAME}-sec-${ENV}"
    ;;
rec)
    TEMPLATE_PATH='./cloudformation/Resource.yml'
    STACK_NAME="${PRODUCT_NAME}-rec-${ENV}"
    ;;
img)
    TEMPLATE_PATH='./cloudformation/Image.yml'
    STACK_NAME="${PRODUCT_NAME}-img-${ENV}"
    ;;
ins)
    TEMPLATE_PATH='./cloudformation/Instance.yml'
    STACK_NAME="${PRODUCT_NAME}-ins-${ENV}"
    ;;
mon)
    TEMPLATE_PATH='./cloudformation/Monitoring.yml'
    STACK_NAME="${PRODUCT_NAME}-mon-${ENV}"
    ;;
fnc)
    TEMPLATE_PATH='./cloudformation/Function.yml'
    STACK_NAME="${PRODUCT_NAME}-fnc-${ENV}"
    ;;
ana)
    TEMPLATE_PATH='./cloudformation/Analytics.yml'
    STACK_NAME="${PRODUCT_NAME}-ana-${ENV}"
    ;;
*)
    echo "error->cfn not supported->${CFN}"
    exit 1
    ;;
esac

echo "CloudFormation Package & Validate Check!! (stack=${STACK_NAME})"

# package: ローカル参照(CodeUri 等)をデプロイ用S3へアップロードしテンプレを書き換える
aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation package \
    --template-file "${TEMPLATE_PATH}" \
    --output-template-file "${DEPLOY_FILE}" \
    --s3-bucket "${S3_BUCKET_NAME}" \
    --s3-prefix "${PRODUCT_NAME}"

echo "CloudFormation Package Success!!"

# 既存スタックのステータスを取得（未作成なら空文字）
STATUS=$(aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[].StackStatus[]" \
    --output text 2>/dev/null || true)
echo "Stack-status is ${STATUS:-NONE}"

# 進行中の操作は完了を待ってからデプロイ
if [ "${STATUS}" = "CREATE_IN_PROGRESS" ]; then
    echo "Wait for CREATE...."
    aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}"
fi

if [ "${STATUS}" = "UPDATE_IN_PROGRESS" ]; then
    echo "Wait for UPDATE...."
    aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation wait stack-update-complete --stack-name "${STACK_NAME}"
fi

if [ "${STATUS}" = "DELETE_IN_PROGRESS" ]; then
    echo "Wait for DELETE...."
    aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"
fi

# ROLLBACK_COMPLETE は更新不能のため一度削除してから作り直す
if [ "${STATUS}" = "ROLLBACK_COMPLETE" ]; then
    echo "Delete rolled-back Stack...."
    aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}"
    aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"
fi

# デプロイ（全スタック共通のパラメータ: Env / ProductName）
aws --profile "${PROFILE}" --region "${AWS_REGION}" cloudformation deploy \
    --template-file "${DEPLOY_FILE}" \
    --stack-name "${STACK_NAME}" \
    --s3-bucket "${S3_BUCKET_NAME}" \
    --s3-prefix "${PRODUCT_NAME}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides Env="${ENV}" ProductName="${PRODUCT_NAME}"

rm -f "${DEPLOY_FILE}"

echo "CloudFormation Deploy Success!! (stack=${STACK_NAME})"
