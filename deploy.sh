#!/usr/bin/env bash
# deploy.sh — Generic Lambda deploy script for special-tech-lambdas
#
# Discovers all lambdas in this repo (any subfolder containing a deploy.conf),
# lets you pick one or deploy all, then creates/updates each one in AWS.
#
# Prerequisites:
#   - AWS CLI configured with the special-tech IAM user credentials
#   - Node.js >= 22 installed locally
#
# Usage (run from the root of this repo):
#   bash deploy.sh               — interactive menu
#   bash deploy.sh image-resizer — deploy a specific lambda directly
#   bash deploy.sh all           — deploy all lambdas without prompting
#
# Re-running is safe — existing resources are updated, not recreated.

set -euo pipefail

# ---------------------------------------------------------------------------
# Global config
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET="${AWS_S3_BUCKET:-special-tech-services}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Resolve SENTRY_DSN: first from environment, then from the backend .env
if [[ -z "${SENTRY_DSN:-}" ]]; then
  BACKEND_ENV="$REPO_ROOT/../special-tech-backend/.env"
  if [[ -f "$BACKEND_ENV" ]]; then
    SENTRY_DSN=$(grep -E '^SENTRY_DSN=' "$BACKEND_ENV" | cut -d '=' -f2- | tr -d '"' | tr -d "'" || true)
  fi
fi
SENTRY_DSN="${SENTRY_DSN:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
bold()    { echo -e "\033[1m$*\033[0m"; }
green()   { echo -e "\033[32m$*\033[0m"; }
yellow()  { echo -e "\033[33m$*\033[0m"; }
red()     { echo -e "\033[31m$*\033[0m"; }
step()    { echo ""; bold "==> $*"; }

# Discover all lambdas: any subfolder with a deploy.conf file
discover_lambdas() {
  local lambdas=()
  for conf in "$REPO_ROOT"/*/deploy.conf; do
    [[ -f "$conf" ]] && lambdas+=("$(basename "$(dirname "$conf")")")
  done
  echo "${lambdas[@]:-}"
}

# ---------------------------------------------------------------------------
# Core deploy function — deploys a single lambda by folder name
# ---------------------------------------------------------------------------
deploy_lambda() {
  local LAMBDA_DIR_NAME="$1"
  local LAMBDA_DIR="$REPO_ROOT/$LAMBDA_DIR_NAME"
  local CONF="$LAMBDA_DIR/deploy.conf"

  if [[ ! -f "$CONF" ]]; then
    red "ERROR: No deploy.conf found in $LAMBDA_DIR"
    return 1
  fi

  # Load lambda-specific config
  # shellcheck source=/dev/null
  source "$CONF"

  local ZIP_PATH="/tmp/special-tech-${LAMBDA_DIR_NAME}.zip"
  local ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

  bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bold " Deploying: $LAMBDA_DIR_NAME"
  bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "   Function : $FUNCTION_NAME"
  echo "   Role     : $ROLE_NAME"
  echo "   Region   : $REGION"
  echo "   Runtime  : $RUNTIME"
  echo "   Memory   : ${MEMORY} MB  |  Timeout: ${TIMEOUT}s"

  # 1. Create IAM role if it doesn't exist
  step "IAM Role"
  if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    yellow "   Role '$ROLE_NAME' already exists, skipping."
  else
    echo "   Creating role '$ROLE_NAME'..."
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"Service":"lambda.amazonaws.com"},
          "Action":"sts:AssumeRole"
        }]
      }' \
      --description "Execution role for Lambda: $FUNCTION_NAME" \
      --output text > /dev/null
    green "   Role created."
  fi

  # 2. Attach CloudWatch Logs policy
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    2>/dev/null || yellow "   AWSLambdaBasicExecutionRole already attached."

  # 3. Run lambda-specific IAM setup hook if defined in deploy.conf
  if declare -f setup_iam > /dev/null 2>&1; then
    step "IAM custom setup (setup_iam hook)"
    setup_iam
    green "   Done."
  fi

  # 4. Install npm dependencies and zip
  step "Packaging"
  echo "   Installing npm dependencies..."
  npm install --prefix "$LAMBDA_DIR" --omit=dev --silent
  echo "   Creating zip..."
  rm -f "$ZIP_PATH"
  (cd "$LAMBDA_DIR" && zip -r "$ZIP_PATH" . \
    --exclude "*.git*" \
    --exclude "deploy.conf" \
    --exclude "*.test.*" \
    > /dev/null)
  green "   Zip ready: $(du -sh "$ZIP_PATH" | cut -f1)"

  # 5. Create or update the Lambda function
  step "Lambda function"
  if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" > /dev/null 2>&1; then
    echo "   Updating code..."
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$ZIP_PATH" \
      --region "$REGION" \
      --output text > /dev/null

    # Wait for update to finish before changing config
    aws lambda wait function-updated \
      --function-name "$FUNCTION_NAME" \
      --region "$REGION"

    echo "   Updating configuration..."
    aws lambda update-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --memory-size "$MEMORY" \
      --timeout "$TIMEOUT" \
      --region "$REGION" \
      --output text > /dev/null
  else
    echo "   Waiting 10s for IAM role propagation..."
    sleep 10
    echo "   Creating Lambda function..."
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://$ZIP_PATH" \
      --memory-size "$MEMORY" \
      --timeout "$TIMEOUT" \
      --description "${DESCRIPTION:-$FUNCTION_NAME}" \
      --region "$REGION" \
      --output text > /dev/null
  fi
  green "   Lambda updated."

  # 6. Inject environment variables
  step "Environment variables"
  if [[ -n "$SENTRY_DSN" ]]; then
    ENV_VARS="Variables={SENTRY_DSN=${SENTRY_DSN},SENTRY_ENVIRONMENT=production}"
    echo "   SENTRY_DSN found and set."
  else
    ENV_VARS="Variables={SENTRY_ENVIRONMENT=production}"
    yellow "   SENTRY_DSN not set — Sentry will be a no-op."
  fi

  # Wait for any in-progress update before touching config again
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "$ENV_VARS" \
    --region "$REGION" \
    --output text > /dev/null

  # 7. Run lambda-specific post-deploy hook if defined in deploy.conf
  if declare -f post_deploy > /dev/null 2>&1; then
    step "Post-deploy (post_deploy hook)"
    post_deploy
    green "   Done."
  fi

  local LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
  echo ""
  green "✓ $LAMBDA_DIR_NAME deployed successfully!"
  echo "  ARN : $LAMBDA_ARN"

  # Unset hook functions so they don't bleed into the next lambda
  unset -f setup_iam 2>/dev/null || true
  unset -f post_deploy 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Resolve AWS Account ID (done once for all lambdas)
# ---------------------------------------------------------------------------
step "Resolving AWS account"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "   Account ID : $ACCOUNT_ID"
echo "   Region     : $REGION"
echo "   Bucket     : $BUCKET"

# Export so deploy.conf hooks can use them
export ACCOUNT_ID REGION BUCKET SENTRY_DSN

# ---------------------------------------------------------------------------
# Determine which lambdas to deploy
# ---------------------------------------------------------------------------
ALL_LAMBDAS=($(discover_lambdas))

if [[ ${#ALL_LAMBDAS[@]} -eq 0 ]]; then
  red "No lambdas found. Create a subfolder with a deploy.conf to get started."
  exit 1
fi

TARGET="${1:-}"  # optional argument: lambda name or "all"

if [[ -n "$TARGET" ]]; then
  # Argument passed directly — validate it
  if [[ "$TARGET" == "all" ]]; then
    SELECTED=("${ALL_LAMBDAS[@]}")
  elif [[ -d "$REPO_ROOT/$TARGET" && -f "$REPO_ROOT/$TARGET/deploy.conf" ]]; then
    SELECTED=("$TARGET")
  else
    red "ERROR: '$TARGET' is not a valid lambda name."
    echo "Available lambdas: ${ALL_LAMBDAS[*]}"
    exit 1
  fi
else
  # Interactive menu
  echo ""
  bold "Available lambdas:"
  echo ""
  for i in "${!ALL_LAMBDAS[@]}"; do
    echo "  [$((i+1))] ${ALL_LAMBDAS[$i]}"
  done
  echo "  [A] All"
  echo "  [Q] Quit"
  echo ""
  read -rp "Which lambda do you want to deploy? " CHOICE

  case "${CHOICE^^}" in
    A)
      SELECTED=("${ALL_LAMBDAS[@]}")
      ;;
    Q)
      echo "Aborted."
      exit 0
      ;;
    *)
      if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#ALL_LAMBDAS[@]} )); then
        SELECTED=("${ALL_LAMBDAS[$((CHOICE-1))]}")
      else
        red "Invalid choice: $CHOICE"
        exit 1
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Deploy selected lambdas
# ---------------------------------------------------------------------------
echo ""
bold "Deploying: ${SELECTED[*]}"

for LAMBDA in "${SELECTED[@]}"; do
  deploy_lambda "$LAMBDA"
done

echo ""
green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
green " All done! Deployed: ${SELECTED[*]}"
green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
