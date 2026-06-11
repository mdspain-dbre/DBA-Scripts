#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Manual backup script:
# - Resolves RDS/Aurora PostgreSQL endpoint from cluster identifier via AWS CLI
# - Enumerates all user databases on the cluster
# - Runs pg_dump for each database in plain SQL format
# - Compresses and uploads each dump directly to GCS (no local dump files)
#
# Required tools:
#   aws, gcloud, pg_dump, psql, gzip
#
# Authentication prerequisites:
#   aws sso login --profile "<your-profile>"
#   gcloud auth login
#   gcloud config set project vz-inscape-portfolio-dev
# -----------------------------------------------------------------------------

# -----------------------------
# User-configurable settings
# -----------------------------
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID_EXPECTED="788724168120"
export SOURCE_CLUSTER_IDENTIFIER="tvc-development-cluster"

export GCP_PROJECT_ID="vz-inscape-portfolio-dev"
export GCS_BUCKET="tvc-db-dump"
export GCS_PREFIX="tvc-development-cluster"

# Cloud SQL target instance for the import step.
export TARGET_CLOUDSQL_INSTANCE="tvc-development"

# Cloud SQL admin (postgres) credentials, used to connect via psql and grant
# privileges after the import completes.
export TARGET_PG_ADMIN_USER="root"
export TARGET_PG_ADMIN_PASSWORD="7dkcib3gl9"

# Application user that should receive admin (read/write/all) privileges on
# every imported database. Created if it does not already exist.
export TARGET_ADMIN_USER="tvc_admin"
export TARGET_ADMIN_PASSWORD="e2!751TdU!05NC4v"

# All users that should receive admin privileges on every imported database.
# TARGET_ADMIN_USER is auto-included; the existing built-in `root` admin is
# also granted so manual psql work continues to have full access.
GRANTEES=("${TARGET_ADMIN_USER}" "${TARGET_PG_ADMIN_USER}")

# Database connection inputs.
export SOURCE_DB_USER="root"
export SOURCE_DB_PASSWORD="7dkcib3gl9"

# Database used for the initial connection to enumerate all databases.
# `postgres` exists by default on RDS PostgreSQL clusters.
export ADMIN_DB="postgres"

# AWS profile used by the AWS CLI. Defaults to the Inscape Production US 1 SSO
# profile; override by exporting AWS_PROFILE before running.
# Refresh credentials with:
#   aws sso login --profile inscape-production-us-1-inscape-aws-ops
export AWS_PROFILE_VALUE="inscape-production-us-1-inscape-aws-ops"

AWS_CALL_ARGS=(--region "${AWS_REGION}")
if [[ -n "${AWS_PROFILE_VALUE}" ]]; then
  AWS_CALL_ARGS+=(--profile "${AWS_PROFILE_VALUE}")
fi

echo "Resolving cluster endpoint for ${SOURCE_CLUSTER_IDENTIFIER}..."
read -r SOURCE_HOST SOURCE_PORT < <(
  aws "${AWS_CALL_ARGS[@]}" rds describe-db-clusters \
    --db-cluster-identifier "${SOURCE_CLUSTER_IDENTIFIER}" \
    --query 'DBClusters[0].[Endpoint,Port]' \
    --output text
)

export SOURCE_HOST SOURCE_PORT
echo "Source endpoint: ${SOURCE_HOST}:${SOURCE_PORT}"

export TS="$(date +%Y%m%d_%H%M%S)"
export RUN_PREFIX="gs://${GCS_BUCKET%/}/${GCS_PREFIX}/${TS}"

# -----------------------------------------------------------------------------
# Enumerate user databases.
# Excludes:
#   - template databases (datistemplate = true)
#   - databases that don't allow connections (datallowconn = false)
#   - RDS-internal admin databases (rdsadmin)
# `pg_dumpall` is intentionally NOT used because Cloud SQL `gcloud sql import sql`
# requires a single-database plain SQL dump; cluster-wide dumps including roles
# and CREATE DATABASE statements are rejected. Each database is dumped
# individually so it can be imported into its own Cloud SQL target database.
# -----------------------------------------------------------------------------
echo "Listing user databases on ${SOURCE_HOST}..."
DATABASES=()
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  DATABASES+=("${line}")
done < <(
  PGPASSWORD="${SOURCE_DB_PASSWORD}" psql \
    --host="${SOURCE_HOST}" \
    --port="${SOURCE_PORT}" \
    --username="${SOURCE_DB_USER}" \
    --dbname="${ADMIN_DB}" \
    --no-align --tuples-only --quiet \
    --command="SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true AND datname NOT IN ('rdsadmin') ORDER BY datname;"
)

if [[ ${#DATABASES[@]} -eq 0 ]]; then
  echo "ERROR: No user databases found on ${SOURCE_HOST}." >&2
  exit 1
fi

echo "Databases to back up (${#DATABASES[@]}):"
printf '  - %s\n' "${DATABASES[@]}"

# -----------------------------------------------------------------------------
# Dump each database individually and stream to GCS.
# -----------------------------------------------------------------------------
FAILED_DBS=()
UPLOADED_URIS=()
for DB in "${DATABASES[@]}"; do
  [[ -z "${DB}" ]] && continue
  export DB
  export GCS_URI="${RUN_PREFIX}/${DB}.sql.gz"
  echo ""
  echo "==> Dumping ${DB} -> ${GCS_URI}"
  if PGPASSWORD="${SOURCE_DB_PASSWORD}" pg_dump \
      --host="${SOURCE_HOST}" \
      --port="${SOURCE_PORT}" \
      --username="${SOURCE_DB_USER}" \
      --dbname="${DB}" \
      --format=plain \
      --encoding=UTF8 \
      --no-owner \
      --no-privileges \
      --quote-all-identifiers \
      | gzip -c \
      | gcloud --project "${GCP_PROJECT_ID}" storage cp - "${GCS_URI}"
  then
    UPLOADED_URIS+=("${GCS_URI}")
  else
    echo "ERROR: pg_dump failed for database ${DB}" >&2
    FAILED_DBS+=("${DB}")
  fi
done

echo ""
echo "Verifying uploaded objects..."
gcloud --project "${GCP_PROJECT_ID}" storage ls -l "${RUN_PREFIX}/" || true

echo ""
echo "Backup summary:"
echo "  Run prefix:    ${RUN_PREFIX}"
echo "  Successful:    ${#UPLOADED_URIS[@]}"
echo "  Failed:        ${#FAILED_DBS[@]}"
if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
  printf '    - %s\n' "${FAILED_DBS[@]}"
  exit 1
fi

echo "Backup complete"

# -----------------------------------------------------------------------------
# Import each dump into Cloud SQL instance ${TARGET_CLOUDSQL_INSTANCE}.
#
# Notes:
# - The Cloud SQL service account for the target instance must have
#   roles/storage.objectViewer on gs://${GCS_BUCKET} (one-time grant).
# - Each target database is created on the instance if it does not already
#   exist; existing databases are reused (import will replay objects into them).
# - `gcloud sql import sql` is single-threaded server-side and runs
#   sequentially per database.
# -----------------------------------------------------------------------------
echo ""
echo "Importing dumps into Cloud SQL instance ${TARGET_CLOUDSQL_INSTANCE}..."

IMPORT_FAILED_DBS=()
for DB in "${DATABASES[@]}"; do
  [[ -z "${DB}" ]] && continue
  export GCS_URI="${RUN_PREFIX}/${DB}.sql.gz"
  echo ""
  echo "==> Ensuring database ${DB} exists on ${TARGET_CLOUDSQL_INSTANCE}"
  if ! gcloud --project "${GCP_PROJECT_ID}" sql databases describe "${DB}" \
        --instance="${TARGET_CLOUDSQL_INSTANCE}" >/dev/null 2>&1; then
    gcloud --project "${GCP_PROJECT_ID}" sql databases create "${DB}" \
      --instance="${TARGET_CLOUDSQL_INSTANCE}" --quiet
  fi

  echo "==> Importing ${GCS_URI} into ${TARGET_CLOUDSQL_INSTANCE}/${DB}"
  if ! gcloud --project "${GCP_PROJECT_ID}" sql import sql \
        "${TARGET_CLOUDSQL_INSTANCE}" "${GCS_URI}" \
        --database="${DB}" --quiet; then
    echo "ERROR: import failed for database ${DB}" >&2
    IMPORT_FAILED_DBS+=("${DB}")
  fi
done

echo ""
echo "Import summary:"
echo "  Instance:   ${TARGET_CLOUDSQL_INSTANCE}"
echo "  Successful: $(( ${#DATABASES[@]} - ${#IMPORT_FAILED_DBS[@]} ))"
echo "  Failed:     ${#IMPORT_FAILED_DBS[@]}"
if [[ ${#IMPORT_FAILED_DBS[@]} -gt 0 ]]; then
  printf '    - %s\n' "${IMPORT_FAILED_DBS[@]}"
  exit 1
fi

echo "Import complete"

# -----------------------------------------------------------------------------
# Grant admin (read/write/all) privileges on every imported database to each
# user in ${GRANTEES[@]}.
#
# Steps:
#   1. Ensure each grantee exists (the built-in `root` always exists; the
#      app user is created via gcloud if missing).
#   2. Grant the Cloud SQL `cloudsqlsuperuser` role (instance-wide admin).
#   3. For each database, grant ALL on the database, schema public, all
#      existing tables/sequences/functions, and set default privileges so
#      future objects are also accessible.
# -----------------------------------------------------------------------------
if [[ -z "${TARGET_PG_ADMIN_PASSWORD}" ]]; then
  echo "ERROR: TARGET_PG_ADMIN_PASSWORD must be set to grant admin privileges." >&2
  exit 1
fi

echo ""
echo "Granting admin privileges to: ${GRANTEES[*]} on ${TARGET_CLOUDSQL_INSTANCE}..."

# Ensure target admin user exists on the Cloud SQL instance.
if ! gcloud --project "${GCP_PROJECT_ID}" sql users list \
      --instance="${TARGET_CLOUDSQL_INSTANCE}" \
      --format='value(name)' | grep -qx "${TARGET_ADMIN_USER}"; then
  if [[ -z "${TARGET_ADMIN_PASSWORD}" ]]; then
    echo "ERROR: ${TARGET_ADMIN_USER} does not exist and TARGET_ADMIN_PASSWORD is empty." >&2
    exit 1
  fi
  echo "Creating user ${TARGET_ADMIN_USER}"
  gcloud --project "${GCP_PROJECT_ID}" sql users create "${TARGET_ADMIN_USER}" \
    --instance="${TARGET_CLOUDSQL_INSTANCE}" \
    --password="${TARGET_ADMIN_PASSWORD}" --quiet
fi

# Resolve the instance's first IP address for psql.
TARGET_HOST="$(gcloud --project "${GCP_PROJECT_ID}" sql instances describe \
  "${TARGET_CLOUDSQL_INSTANCE}" --format='value(ipAddresses[0].ipAddress)')"
export TARGET_HOST

if [[ -z "${TARGET_HOST}" ]]; then
  echo "ERROR: Could not resolve IP for Cloud SQL instance ${TARGET_CLOUDSQL_INSTANCE}." >&2
  exit 1
fi

# Instance-level: grant cloudsqlsuperuser (Cloud SQL admin role) to each grantee.
for GRANTEE in "${GRANTEES[@]}"; do
  [[ -z "${GRANTEE}" ]] && continue
  PGPASSWORD="${TARGET_PG_ADMIN_PASSWORD}" psql \
    --host="${TARGET_HOST}" \
    --username="${TARGET_PG_ADMIN_USER}" \
    --dbname="postgres" \
    --quiet --no-psqlrc \
    --command="GRANT cloudsqlsuperuser TO \"${GRANTEE}\";"
done

# Per-database: grant full privileges and set defaults for future objects.
for DB in "${DATABASES[@]}"; do
  [[ -z "${DB}" ]] && continue
  for GRANTEE in "${GRANTEES[@]}"; do
    [[ -z "${GRANTEE}" ]] && continue
    echo "==> Granting privileges on ${DB} to ${GRANTEE}"
    PGPASSWORD="${TARGET_PG_ADMIN_PASSWORD}" psql \
      --host="${TARGET_HOST}" \
      --username="${TARGET_PG_ADMIN_USER}" \
      --dbname="${DB}" \
      --quiet --no-psqlrc \
      --set=ON_ERROR_STOP=1 \
      --command="
GRANT ALL PRIVILEGES ON DATABASE \"${DB}\" TO \"${GRANTEE}\";
GRANT ALL ON SCHEMA public TO \"${GRANTEE}\";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"${GRANTEE}\";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"${GRANTEE}\";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO \"${GRANTEE}\";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${GRANTEE}\";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${GRANTEE}\";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO \"${GRANTEE}\";
"
  done
done

echo ""
echo "Privilege grants complete"