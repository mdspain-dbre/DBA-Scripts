#!/usr/bin/env bash
# Verifies AWS CLI + gcloud auth on VS Code startup.
# Prompts for re-login only if credentials are missing/expired.

set -u

echo "==> Checking AWS CLI credentials..."
if aws sts get-caller-identity >/dev/null 2>&1; then
    IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
    echo "    [OK] AWS: $IDENTITY"
else
    echo "    [WARN] AWS credentials missing or invalid."
    echo "    Edit ~/.aws/credentials or run: aws configure"
fi

echo ""
echo "==> Checking gcloud credentials..."
ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$ACTIVE_ACCT" ]; then
    echo "    [OK] gcloud user: $ACTIVE_ACCT"
else
    echo "    [WARN] No active gcloud account. Launching: gcloud auth login"
    gcloud auth login
fi

# Application Default Credentials (used by SDKs / Terraform google provider)
ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"
if [ -f "$ADC_FILE" ]; then
    echo "    [OK] gcloud ADC present"
else
    echo "    [WARN] No Application Default Credentials. Launching: gcloud auth application-default login"
    gcloud auth application-default login
fi

echo ""
echo "==> Auth check complete."
