#!/usr/bin/env bash
# Verifies AWS CLI + gcloud auth on VS Code startup.
# Prompts for re-login only if credentials are missing/expired.

set -u

# Set the AWS profile to validate/login on VS Code startup.
# Override by exporting AWS_AUTH_PROFILE before running this script.
AWS_AUTH_PROFILE="${AWS_AUTH_PROFILE:-inscape-finops-inscape-aws-ops}"

# Set gcloud identity defaults for VS Code startup.
# Option 1: export env vars before launching VS Code.
#   export GCLOUD_AUTH_ACCOUNT="you@example.com"
#   export GCLOUD_AUTH_PROJECT="your-gcp-project-id"
# Option 2: set the defaults below directly in this file.
GCLOUD_AUTH_ACCOUNT="${GCLOUD_AUTH_ACCOUNT:-michael.dspain@vizio.com}"
GCLOUD_AUTH_PROJECT="${GCLOUD_AUTH_PROJECT:-vz-inscape-portfolio-dev}"

echo "==> Checking AWS CLI credentials..."
if aws sts get-caller-identity --profile "$AWS_AUTH_PROFILE" >/dev/null 2>&1; then
    IDENTITY=$(aws sts get-caller-identity --profile "$AWS_AUTH_PROFILE" --query Arn --output text)
    echo "    [OK] AWS profile '$AWS_AUTH_PROFILE': $IDENTITY"
else
    echo "    [WARN] AWS credentials missing/expired for profile '$AWS_AUTH_PROFILE'."

    if aws configure get sso_start_url --profile "$AWS_AUTH_PROFILE" >/dev/null 2>&1; then
        echo "    [INFO] Launching: aws sso login --profile $AWS_AUTH_PROFILE"
        if aws sso login --profile "$AWS_AUTH_PROFILE"; then
            IDENTITY=$(aws sts get-caller-identity --profile "$AWS_AUTH_PROFILE" --query Arn --output text 2>/dev/null || true)
            if [ -n "$IDENTITY" ]; then
                echo "    [OK] AWS profile '$AWS_AUTH_PROFILE': $IDENTITY"
            else
                echo "    [WARN] AWS SSO login completed, but identity check failed for '$AWS_AUTH_PROFILE'."
            fi
        else
            echo "    [WARN] AWS SSO login failed for profile '$AWS_AUTH_PROFILE'."
        fi
    else
        echo "    [WARN] Profile '$AWS_AUTH_PROFILE' is not configured for SSO."
        echo "    Run one of: aws configure sso --profile $AWS_AUTH_PROFILE | aws configure --profile $AWS_AUTH_PROFILE"
    fi
fi

echo ""
echo "==> Checking gcloud credentials..."
ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$GCLOUD_AUTH_ACCOUNT" ]; then
    if gcloud auth list --format="value(account)" 2>/dev/null | grep -Fxq "$GCLOUD_AUTH_ACCOUNT"; then
        echo "    [INFO] gcloud account '$GCLOUD_AUTH_ACCOUNT' is already known."
    else
        echo "    [WARN] gcloud account '$GCLOUD_AUTH_ACCOUNT' is not authenticated. Launching: gcloud auth login"
        gcloud auth login
    fi

    gcloud config set account "$GCLOUD_AUTH_ACCOUNT" >/dev/null

    if gcloud auth print-access-token --account="$GCLOUD_AUTH_ACCOUNT" >/dev/null 2>&1; then
        echo "    [OK] gcloud user: $GCLOUD_AUTH_ACCOUNT"
    else
        echo "    [WARN] gcloud token missing/expired for '$GCLOUD_AUTH_ACCOUNT'. Launching: gcloud auth login"
        gcloud auth login
    fi
elif [ -n "$ACTIVE_ACCT" ]; then
    if gcloud auth print-access-token >/dev/null 2>&1; then
        echo "    [OK] gcloud user: $ACTIVE_ACCT"
    else
        echo "    [WARN] Active gcloud account token missing/expired. Launching: gcloud auth login"
        gcloud auth login
    fi
else
    echo "    [WARN] No active gcloud account. Launching: gcloud auth login"
    gcloud auth login
fi

if [ -n "$GCLOUD_AUTH_PROJECT" ]; then
    if gcloud config set project "$GCLOUD_AUTH_PROJECT" >/dev/null 2>&1; then
        echo "    [OK] gcloud project: $GCLOUD_AUTH_PROJECT"
    else
        echo "    [WARN] Could not set gcloud project '$GCLOUD_AUTH_PROJECT'."
    fi
fi

# Application Default Credentials (used by SDKs / Terraform google provider)
ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"
if [ -f "$ADC_FILE" ] && gcloud auth application-default print-access-token >/dev/null 2>&1; then
    echo "    [OK] gcloud ADC present"
else
    echo "    [WARN] No valid Application Default Credentials. Launching: gcloud auth application-default login"
    gcloud auth application-default login
fi

echo ""
echo "==> Auth check complete."
