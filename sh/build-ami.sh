#!/bin/bash
#
# build-ami.sh - Minecraft サーバー用のカスタム AMI を焼成する。
#
# 目的:
#   install.sh の Step 2（dnf install java-22 / cwagent / mcrcon ビルド）は
#   インスタンス起動毎に 1〜2 分かかる。これらを事前に焼き込んだ AMI を作って
#   /minecraft/prd/ami-id に登録しておけば、スポット中断後の復旧時間を短縮できる。
#
# フロー:
#   1. AL2023 arm64 標準 AMI で一時 EC2 を起動（既存の SecurityGroup / InstanceProfile を再利用）
#   2. SSM Send Command で依存導入（java-22 / cwagent / mcrcon）
#   3. 一時 EC2 を stop → CreateImage で AMI 焼成 → AMI available 待ち
#   4. SSM Parameter /minecraft/prd/ami-id を新 AMI ID で put（無ければ作成、あれば上書き）
#   5. 一時 EC2 を terminate
#   6. 古いカスタム AMI（最新 KEEP_AMI_COUNT 個以外）を deregister + snapshot 削除
#
# 実行環境: GitHub Actions(ubuntu) を想定。aws CLI / curl / sleep が前提。
# 必要権限: ec2 RunInstances/StopInstances/TerminateInstances/CreateImage/DescribeImages/
#         DeregisterImage/DescribeSnapshots/DeleteSnapshot/DescribeInstances/Wait系,
#         ssm SendCommand/GetCommandInvocation/PutParameter, iam PassRole（InstanceProfile）,
#         cloudformation ListExports（既存リソース ARN/ID 取得）。

set -euo pipefail

# -----------------------------------------------------------------------------
# 定数
# -----------------------------------------------------------------------------
REGION="ap-northeast-1"
PRODUCT_NAME="minecraft"
ENV="prd"
# ビルド用一時 EC2 のタイプ（コストは数分で済むため最安に近い arm64 で十分）。
BUILD_INSTANCE_TYPE="c6g.medium"
# AL2023 arm64 標準 AMI を SSM パブリックパラメータから取得する。
BASE_AMI_SSM_NAME="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
# 焼成後の AMI ID を書き込む SSM Parameter 名（Instance.yml がこれを参照する想定）。
TARGET_AMI_SSM_NAME="/${PRODUCT_NAME}/${ENV}/ami-id"
# 保持する古いカスタム AMI の数（最新 N 個以外は deregister + snapshot 削除）。
KEEP_AMI_COUNT=2
# AMI 名のプリフィックス（タグでフィルタするため）。
AMI_NAME_PREFIX="${PRODUCT_NAME}-${ENV}-prebaked"

# -----------------------------------------------------------------------------
# CFn Export から既存リソースを取得
# -----------------------------------------------------------------------------
echo "=== fetch existing resources from CFn exports ==="
SUBNET_ID="$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='${PRODUCT_NAME}-public-subnet-ids-all'].Value" --output text \
    | cut -d',' -f1)"
SG_ID="$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='${PRODUCT_NAME}-mc-sg-id'].Value" --output text)"
INSTANCE_PROFILE_ARN="$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='${PRODUCT_NAME}-ec2-instance-profile-arn'].Value" --output text)"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_ARN##*/}"

if [ -z "$SUBNET_ID" ] || [ -z "$SG_ID" ] || [ -z "$INSTANCE_PROFILE_NAME" ]; then
    echo "error->required CFn exports not found (net/sec/ins スタックがデプロイ済みか確認)" >&2
    exit 1
fi

BASE_AMI_ID="$(aws ssm get-parameter --region "$REGION" \
    --name "$BASE_AMI_SSM_NAME" --query 'Parameter.Value' --output text)"

echo "  subnet           : $SUBNET_ID"
echo "  security group   : $SG_ID"
echo "  instance profile : $INSTANCE_PROFILE_NAME"
echo "  base AMI         : $BASE_AMI_ID"

# -----------------------------------------------------------------------------
# 1. 一時 EC2 起動
# -----------------------------------------------------------------------------
echo ""
echo "=== [1/6] launch temporary build instance ==="
INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
    --image-id "$BASE_AMI_ID" \
    --instance-type "$BUILD_INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PRODUCT_NAME}-ami-build},{Key=Purpose,Value=ami-build}]" \
    --query 'Instances[0].InstanceId' --output text)"
echo "  instance: $INSTANCE_ID"

# クリーンアップ: スクリプト異常終了時にも一時 EC2 を確実に terminate する。
function cleanup_instance {
    local rc=$?
    if [ -n "${INSTANCE_ID:-}" ]; then
        echo "  cleanup: terminate $INSTANCE_ID"
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup_instance EXIT

echo "  wait for instance-running"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# SSM Agent が登録されるまで少し待つ（即実行だと InvalidInstanceId エラーになる）。
echo "  wait for SSM agent registration"
for _ in $(seq 1 30); do
    if aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].InstanceId' --output text 2>/dev/null \
        | grep -q "$INSTANCE_ID"; then
        break
    fi
    sleep 10
done

# -----------------------------------------------------------------------------
# 2. 依存導入（install.sh の Step 2 と等価）
# -----------------------------------------------------------------------------
echo ""
echo "=== [2/6] install dependencies via SSM Run Command ==="
CMD_ID="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "minecraft ami build: install java22 / cwagent / mcrcon" \
    --parameters '{"commands":[
        "set -euo pipefail",
        "dnf install -y java-22-amazon-corretto-headless amazon-cloudwatch-agent gcc git",
        "BUILD_DIR=$(mktemp -d)",
        "git clone --depth 1 https://github.com/Tiiffi/mcrcon.git \"$BUILD_DIR/mcrcon\"",
        "gcc -std=gnu11 -O2 -o /usr/local/bin/mcrcon \"$BUILD_DIR/mcrcon/mcrcon.c\"",
        "chmod +x /usr/local/bin/mcrcon",
        "rm -rf \"$BUILD_DIR\"",
        "dnf clean all",
        "rm -rf /var/cache/dnf"
    ]}' \
    --query 'Command.CommandId' --output text)"
echo "  command id: $CMD_ID"

echo "  wait for command completion"
aws ssm wait command-executed --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID"
echo "  command completed"

# -----------------------------------------------------------------------------
# 3. stop → CreateImage
# -----------------------------------------------------------------------------
echo ""
echo "=== [3/6] stop instance and create image ==="
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

# AMI 名は時刻でユニーク化。タグ Purpose=ami-build でフィルタしやすくする。
AMI_NAME="${AMI_NAME_PREFIX}-$(date -u +%Y%m%d-%H%M%S)"
NEW_AMI_ID="$(aws ec2 create-image --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "Pre-baked AMI for minecraft (java22 / cwagent / mcrcon)" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Purpose,Value=ami-build},{Key=ProductName,Value=${PRODUCT_NAME}},{Key=Env,Value=${ENV}}]" \
    --query 'ImageId' --output text)"
echo "  new AMI: $NEW_AMI_ID ($AMI_NAME)"

echo "  wait for image-available"
aws ec2 wait image-available --region "$REGION" --image-ids "$NEW_AMI_ID"

# -----------------------------------------------------------------------------
# 4. SSM Parameter 更新（無ければ作成、あれば上書き）
# -----------------------------------------------------------------------------
echo ""
echo "=== [4/6] update SSM Parameter $TARGET_AMI_SSM_NAME ==="
aws ssm put-parameter --region "$REGION" \
    --name "$TARGET_AMI_SSM_NAME" \
    --value "$NEW_AMI_ID" \
    --type String \
    --description "Pre-baked AMI for minecraft. Updated by sh/build-ami.sh." \
    --overwrite \
    >/dev/null
echo "  $TARGET_AMI_SSM_NAME = $NEW_AMI_ID"

# -----------------------------------------------------------------------------
# 5. 一時 EC2 を terminate（trap でも保険があるが、ここで明示削除）
# -----------------------------------------------------------------------------
echo ""
echo "=== [5/6] terminate temporary build instance ==="
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
INSTANCE_ID=""  # trap で再 terminate しないよう空にする
echo "  terminated"

# -----------------------------------------------------------------------------
# 6. 古いカスタム AMI を整理（最新 KEEP_AMI_COUNT 個以外を削除）
# -----------------------------------------------------------------------------
echo ""
echo "=== [6/6] prune old AMIs (keep latest $KEEP_AMI_COUNT) ==="
OLD_AMIS="$(aws ec2 describe-images --region "$REGION" \
    --owners self \
    --filters "Name=tag:Purpose,Values=ami-build" "Name=tag:ProductName,Values=${PRODUCT_NAME}" "Name=tag:Env,Values=${ENV}" \
    --query "sort_by(Images,&CreationDate) | [:-${KEEP_AMI_COUNT}].ImageId" \
    --output text)"
if [ -z "$OLD_AMIS" ] || [ "$OLD_AMIS" = "None" ]; then
    echo "  no old AMIs to prune"
else
    for AMI in $OLD_AMIS; do
        echo "  deregister $AMI"
        SNAP_IDS="$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" \
            --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text)"
        aws ec2 deregister-image --region "$REGION" --image-id "$AMI"
        for SNAP in $SNAP_IDS; do
            [ -n "$SNAP" ] && [ "$SNAP" != "None" ] || continue
            echo "    delete snapshot $SNAP"
            aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAP" || true
        done
    done
fi

echo ""
echo "=== AMI build complete: $NEW_AMI_ID ==="
