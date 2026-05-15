#!/usr/bin/env bash
# Deploy the mysql_dba_agent ADK agent to Cloud Run.
# Docs: https://google.github.io/adk-docs/deploy/cloud-run/

set -euo pipefail

# --------- Configuration ---------
PROJECT_ID="${PROJECT_ID:-dre-sandbox-471618}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-mysql-dba-agent}"
SA_NAME="${SA_NAME:-mysql-dba-agent-sa}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Toolbox (private Cloud Run) the agent will call
TOOLBOX_URL="${TOOLBOX_URL:-https://mcp-toolbox-mysql-cd6say4hnq-uc.a.run.app}"
TOOLBOX_SERVICE="${TOOLBOX_SERVICE:-mcp-toolbox-mysql}"

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_MODULE_DIR="${AGENT_DIR}/mysql_dba_agent"

# ---------------------------------

echo "==> Project: $PROJECT_ID  Region: $REGION  Service: $SERVICE"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "==> Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  aiplatform.googleapis.com \
  iam.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com

echo "==> Creating service account (idempotent)"
if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="MySQL DBA Agent Cloud Run SA"
fi

echo "==> Granting roles to agent service account"
for role in \
  roles/aiplatform.user \
  roles/logging.logWriter
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" \
    --condition=None >/dev/null
done

echo "==> Granting agent SA invoker access to Toolbox service ($TOOLBOX_SERVICE)"
gcloud run services add-iam-policy-binding "$TOOLBOX_SERVICE" \
  --region="$REGION" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" >/dev/null

echo "==> Deploying agent with 'adk deploy cloud_run'"
cd "$AGENT_DIR"

adk deploy cloud_run \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --service_name="$SERVICE" \
  --app_name=mysql_dba_agent \
  --with_ui \
  "$AGENT_MODULE_DIR"

echo "==> Patching service: SA and env vars"
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --service-account="$SA_EMAIL" \
  --update-env-vars="TOOLBOX_URL=${TOOLBOX_URL},GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=${REGION}"

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')
echo
echo "==> Deployed: $URL"
echo "==> Grant access to additional users with:"
echo "    gcloud run services add-iam-policy-binding $SERVICE \\"
echo "      --region=$REGION \\"
echo "      --member='user:someone@example.com' \\"
echo "      --role='roles/run.invoker'"
echo
echo "==> Open in browser (uses your gcloud identity):"
echo "    gcloud run services proxy $SERVICE --region=$REGION"
echo "    then visit http://localhost:8080"
