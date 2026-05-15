#!/usr/bin/env bash
# Deploy MCP Toolbox to Cloud Run, backed by Cloud SQL (MySQL).
# Docs: https://googleapis.github.io/genai-toolbox/how-to/deploy-toolbox/deploy-cloud-run/
#
# Prereqs:
#   - gcloud authenticated (gcloud auth login)
#   - Roles on yourself: Cloud Run Admin, Service Account Admin,
#     Secret Manager Admin, Cloud SQL Admin, Service Usage Admin

set -euo pipefail

# --------- Configuration ---------
PROJECT_ID="${PROJECT_ID:-dre-sandbox-471618}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mcp-toolbox-mysql}"
SA_NAME="${SA_NAME:-mcp-toolbox-sa}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-${PROJECT_ID}:${REGION}:sakilamysql}"

# Secret names in Secret Manager
SECRET_USER="${SECRET_USER:-mcp-toolbox-mysql-user}"
SECRET_PASS="${SECRET_PASS:-mcp-toolbox-mysql-password}"
SECRET_CONFIG="${SECRET_CONFIG:-mcp-toolbox-tools-yaml}"

# Toolbox container image
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:latest}"

CONFIG_FILE="${CONFIG_FILE:-tools.yaml}"

# ---------------------------------

echo "==> Project: $PROJECT_ID  Region: $REGION  Service: $SERVICE"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "==> Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  artifactregistry.googleapis.com

echo "==> Creating service account (idempotent)"
if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="MCP Toolbox Cloud Run SA"
fi

echo "==> Granting roles to service account"
for role in \
  roles/cloudsql.client \
  roles/secretmanager.secretAccessor \
  roles/logging.logWriter
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" \
    --condition=None >/dev/null
done

echo "==> Ensuring secrets exist (will not overwrite values)"
ensure_secret() {
  local name="$1"
  if ! gcloud secrets describe "$name" >/dev/null 2>&1; then
    gcloud secrets create "$name" --replication-policy=automatic
    echo "    Created secret '$name' — add a version with:"
    echo "      printf 'VALUE' | gcloud secrets versions add $name --data-file=-"
  fi
}
ensure_secret "$SECRET_USER"
ensure_secret "$SECRET_PASS"

echo "==> Uploading $CONFIG_FILE as secret '$SECRET_CONFIG'"
if ! gcloud secrets describe "$SECRET_CONFIG" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET_CONFIG" --replication-policy=automatic
fi
gcloud secrets versions add "$SECRET_CONFIG" --data-file="$CONFIG_FILE"

# Verify the credential secrets actually have versions before deploying
for s in "$SECRET_USER" "$SECRET_PASS"; do
  if ! gcloud secrets versions list "$s" --limit=1 --format='value(name)' | grep -q .; then
    echo "ERROR: Secret '$s' has no versions. Add one with:"
    echo "  printf 'VALUE' | gcloud secrets versions add $s --data-file=-"
    exit 1
  fi
done

echo "==> Deploying Cloud Run service '$SERVICE'"
gcloud run deploy "$SERVICE" \
  --image="$TOOLBOX_IMAGE" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --no-allow-unauthenticated \
  --add-cloudsql-instances="$CLOUDSQL_INSTANCE" \
  --set-secrets="MYSQL_USER=${SECRET_USER}:latest,MYSQL_PASSWORD=${SECRET_PASS}:latest,/config/tools.yaml=${SECRET_CONFIG}:latest" \
  --args="--config,/config/tools.yaml,--address,0.0.0.0,--port,8080" \
  --port=8080 \
  --cpu=1 --memory=512Mi \
  --min-instances=0 --max-instances=3

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')
echo
echo "==> Deployed: $URL"
echo "==> Test (requires identity token):"
echo "    curl -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" \\"
echo "         -H 'Accept: application/json, text/event-stream' \\"
echo "         -X POST $URL/mcp \\"
echo "         -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"
