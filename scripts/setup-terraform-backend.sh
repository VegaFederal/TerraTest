#!/bin/bash
# One-time setup: creates the S3 bucket + DynamoDB lock table Terraform
# state lives in, then writes infrastructure/terraform/backend.hcl so
# `terraform init -backend-config=backend.hcl` can find them. Safe to
# re-run — every AWS call is idempotent.
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}Terraform Backend Setup${NC}"
echo -e "${BLUE}=========================================${NC}"

CONFIG_FILE="config/project-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${YELLOW}Error: $CONFIG_FILE not found. Run ./scripts/init.sh first.${NC}"
  exit 1
fi

PROJECT_NAME=$(grep -o '"projectName": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4)
AWS_REGION=$(grep -o '"awsRegion": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4)
PROJECT_NAME_LOWER=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

BUCKET_NAME="${PROJECT_NAME_LOWER}-tfstate-${ACCOUNT_ID}"
TABLE_NAME="${PROJECT_NAME_LOWER}-tfstate-lock"

echo "Project:      $PROJECT_NAME"
echo "AWS account:  $ACCOUNT_ID"
echo "Region:       $AWS_REGION"
echo "State bucket: $BUCKET_NAME"
echo "Lock table:   $TABLE_NAME"
echo ""

# S3 bucket for state. Standard storage class — state files are typically a
# few KB, so this is the cheapest possible durable option and runs to
# fractions of a cent a month.
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket $BUCKET_NAME already exists, skipping creation."
else
  echo "Creating bucket $BUCKET_NAME..."
  if [ "$AWS_REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
fi

aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# DynamoDB table for state locking, on-demand billing. A lock table is only
# touched during `terraform plan`/`apply`, so on-demand (pay per request,
# no reserved throughput) runs to a fraction of a cent a month — the
# cheapest locking option that still works with any Terraform CLI version
# (native S3 locking is cheaper still, but needs Terraform >= 1.10, which
# this template doesn't require or pin anywhere).
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Table $TABLE_NAME already exists, skipping creation."
else
  echo "Creating table $TABLE_NAME..."
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" > /dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
fi

cat > infrastructure/terraform/backend.hcl << EOL
bucket         = "$BUCKET_NAME"
region         = "$AWS_REGION"
dynamodb_table = "$TABLE_NAME"
EOL

echo ""
echo -e "${GREEN}Backend ready.${NC} Commit infrastructure/terraform/backend.hcl, then run:"
echo "  cd infrastructure/terraform && terraform init -backend-config=backend.hcl"
