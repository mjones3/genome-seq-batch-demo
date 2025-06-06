#!/usr/bin/env bash
set -euo pipefail

# Determine the project root (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"

echo "Project root is: $PROJECT_ROOT"

#############################
# 1. Package Lambdas if changed
#############################
lambda_names=("chunkerFunction" "aggregatorFunction" "starterFunction")
lambda_dirs=(
  "${PROJECT_ROOT}/functions/chunker"
  "${PROJECT_ROOT}/functions/aggregator"
  "${PROJECT_ROOT}/functions/starter"
)

changed_lambdas=()

for i in "${!lambda_names[@]}"; do
  lambda="${lambda_names[$i]}"
  LAMBDA_DIR="${lambda_dirs[$i]}"
  ZIP_FILE="${LAMBDA_DIR}/${lambda}.zip"
  CHECKSUM_FILE="${PROJECT_ROOT}/${lambda}.checksum"

  echo "-------------------------------------------------------"
  echo "Checking for changes in $lambda (source: $LAMBDA_DIR)..."

  CURRENT_CHECKSUM=$(find "$LAMBDA_DIR" -type f -exec sha256sum {} \; | sort | sha256sum | awk '{print $1}')
  STORED_CHECKSUM=""
  if [ -f "$CHECKSUM_FILE" ]; then
    STORED_CHECKSUM=$(<"$CHECKSUM_FILE")
  fi

  if [ "$CURRENT_CHECKSUM" != "$STORED_CHECKSUM" ]; then
    echo "Changes detected for $lambda. Packaging into $ZIP_FILE..."
    pushd "$LAMBDA_DIR" > /dev/null
    zip -r "${lambda}.zip" ./*
    popd > /dev/null

    echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
    changed_lambdas+=("$lambda")
  else
    echo "No changes for $lambda; skipping."
  fi
done

# 2. Build & Push Batch Container to ECR
echo "-------------------------------------------------------"
echo "Building and pushing the process-chunk container to ECR..."

# 2a. Terraform apply to ensure ECR repo exists (and capture its URL)
cd "${PROJECT_ROOT}/terraform"
terraform init -input=false
terraform apply -auto-approve

# Assume terraform output declares `ecr_repository_url`
ECR_REPO_URL=$(terraform output -raw ecr_repository_url)
echo "ECR repository URL: $ECR_REPO_URL"

cd "$PROJECT_ROOT/app/process-chunk"

# Define image tag (use "latest" or pass as first arg)
IMAGE_TAG=${1:-"latest"}
IMAGE_FULL_TAG="${ECR_REPO_URL}:process-chunk-${IMAGE_TAG}"

echo "Logging into ECR..."
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${ECR_REPO_URL%/*}"

echo "Building Docker image for process-chunk: $IMAGE_FULL_TAG..."
docker build --platform linux/amd64 -t "${IMAGE_FULL_TAG}" .

echo "Pushing Docker image to ECR..."
docker push "${IMAGE_FULL_TAG}"

echo "-------------------------------------------------------"
cd "$PROJECT_ROOT"

# 3. Terraform apply (again, to pick up new image tag if needed)
echo "-------------------------------------------------------"
echo "Re-running Terraform to update any references to the new image tag..."

cd "${PROJECT_ROOT}/terraform"
terraform apply -auto-approve

echo "-------------------------------------------------------"
cd "$PROJECT_ROOT"

# 4. Create or Update Lambdas
for fn in "${lambda_names[@]}"; do
  ZIP_PATH="${PROJECT_ROOT}/functions/${fn/Function/}/${fn}.zip"  # e.g., functions/chunker/chunkerFunction.zip

  if [ ! -f "$ZIP_PATH" ]; then
    echo "⚠️  ZIP for $fn not found at $ZIP_PATH; skipping."
    continue
  fi

  echo "-------------------------------------------------------"
  echo "Checking if Lambda '$fn' exists..."

  if aws lambda get-function --function-name "$fn" > /dev/null 2>&1; then
    echo "✔  Lambda '$fn' exists; updating code..."
    aws lambda update-function-code \
      --function-name "$fn" \
      --zip-file "fileb://${ZIP_PATH}"
    echo "✔  Updated code for $fn"
  else
    echo "🔧 Lambda '$fn' not found; creating..."

    # Retrieve the IAM role ARN that Terraform created for Lambdas
    LAMBDA_ROLE_NAME="genome_lambda_role"
    ROLE_ARN="$(aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" --query 'Role.Arn' --output text)"

    # Determine handler string and runtime
    RUNTIME="python3.9"
    HANDLER="handler.handler"   # assumes handler.py defines a 'handler' function

    aws lambda create-function \
      --function-name "$fn" \
      --runtime "$RUNTIME" \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://${ZIP_PATH}"

    echo "✔  Created Lambda '$fn'"
  fi
done

echo "-------------------------------------------------------"
echo "Deployment complete."
