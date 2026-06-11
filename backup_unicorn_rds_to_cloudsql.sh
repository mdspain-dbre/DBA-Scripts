#!/usr/bin/env bash
# =============================================================================
# backup_unicorn_rds_to_cloudsql.sh
# =============================================================================
# Purpose
#   Migrate the `unicorn` PostgreSQL database from AWS RDS to GCP Cloud SQL by:
#     1. Streaming a pg_dump of the source RDS database,
#     2. Compressing the stream with gzip on the fly,
#     3. Uploading the gzipped dump straight to a GCS bucket (no local file),
#     4. Triggering a Cloud SQL `import sql` to load it into the target DB.
#
#   Because the dump is streamed end-to-end, no intermediate local copy of the
#   ~24 GB dump is written to disk on the workstation running this script.
#
# Pipeline
#   pg_dump (RDS) ──► gzip -c ──► gcloud storage cp - gs://...sql.gz
#                                                   │
#                                                   ▼
#                              gcloud sql import sql admin-portal-db ...
#
# Prerequisites (not validated here on purpose — fail fast on first real call)
#   - aws CLI authenticated for AWS_PROFILE (run `aws sso login` first)
#   - gcloud authenticated against GCP_PROJECT_ID
#   - PostgreSQL 18 client tools installed at PG_DUMP_BIN
#       brew install postgresql@18
#   - The Cloud SQL instance's service agent has roles/storage.objectViewer
#     on the destination GCS bucket (otherwise the import step fails with
#     HTTP 412). This is granted by a project admin once per bucket:
#       gcloud storage buckets add-iam-policy-binding gs://<bucket> \
#         --member=serviceAccount:<cloudsql-sa>@gcp-sa-cloud-sql.iam.gserviceaccount.com \
#         --role=roles/storage.objectViewer
#   - The target database (TARGET_DB) already exists on the Cloud SQL instance
#
# Shell options
#   -e          exit on any command failure
#   -u          error on use of unset variables
#   -o pipefail any failure in the pg_dump | gzip | gcloud pipeline aborts the
#               whole pipeline (so a partial/corrupt object is never imported)
# =============================================================================
set -euo pipefail

#######################################
# Configuration
#######################################
# --- AWS source (RDS PostgreSQL) -------------------------------------------
# AWS_PROFILE / AWS_REGION are read by the aws CLI below.
export AWS_PROFILE=inscape-production-us-1-inscape-aws-ops
export AWS_REGION=us-east-1

# RDS instance identifier (not the endpoint hostname). The endpoint is looked
# up at runtime via `aws rds describe-db-instances`.
export SOURCE_RDS_INSTANCE=prod-rds-unicorn-dev-pg18

# Source database, user, and password used by pg_dump.
# NOTE: secrets are inlined here for convenience; rotate after migration and
# consider moving to AWS Secrets Manager / GCP Secret Manager for production.
export SOURCE_DB=unicorn
export SOURCE_DB_USER=root
export SOURCE_DB_PASSWORD='KVV0hjhRf&zGXK9j'

# --- GCP target (Cloud SQL PostgreSQL) -------------------------------------
export GCP_PROJECT_ID=vz-inscape-portfolio-dev
export TARGET_CLOUDSQL_INSTANCE=admin-portal-db   # Cloud SQL instance name
export TARGET_DB=unicorn                          # Database inside that instance
export TARGET_DB_USER=postgres                    # Owner used by Cloud SQL import
export TARGET_DB_PASSWORD='rRxj*no9Jl~oIZ$)'      # (Not used by `gcloud sql import`; kept for ad-hoc psql use)

# --- GCS staging area for the dump -----------------------------------------
export GCS_BUCKET=pointsdb-backup
export GCS_PREFIX=unicorn-postgres

# --- Behavior flags --------------------------------------------------------
# IMPORT_ASYNC=true  -> kick off `gcloud sql import sql` with --async and just
#                       print the operation id (lets the script return quickly).
# IMPORT_ASYNC=false -> wait for the import to finish (blocking).
export IMPORT_ASYNC=false

# pg_dump major version MUST be >= the source server major version (PG 18.x
# here). Hardcoded to the Homebrew postgresql@18 install path; override by
# exporting PG_DUMP_BIN before running the script.
export PG_DUMP_BIN=/opt/homebrew/opt/postgresql@18/bin/pg_dump

#######################################
# Resolve source RDS endpoint
#######################################
# `aws rds describe-db-instances` returns the public/private endpoint
# (Address) and Port. We ask for both as a single tab-separated line and
# split it into SOURCE_HOST / SOURCE_PORT with `read`.
# Using `< <( ... )` (process substitution) so `read` runs in the current
# shell — a normal pipe would put `read` in a subshell and lose the values.
read -r SOURCE_HOST SOURCE_PORT < <(
  aws rds describe-db-instances \
    --db-instance-identifier "${SOURCE_RDS_INSTANCE}" \
    --query 'DBInstances[0].Endpoint.[Address,Port]' --output text
)
echo "Source RDS: ${SOURCE_HOST}:${SOURCE_PORT}"

# Timestamp embedded in the GCS object name so each run produces a unique
# object and old dumps are not overwritten.
TS="$(date +%Y%m%d_%H%M%S)"

# Final destination URI, e.g.:
#   gs://pointsdb-backup/unicorn-postgres/unicorn_20260609_164916.sql.gz
# `${GCS_BUCKET%/}` trims a trailing slash if one was accidentally configured.
GCS_URI="gs://${GCS_BUCKET%/}/${GCS_PREFIX}/${SOURCE_DB}_${TS}.sql.gz"

#######################################
# Stream pg_dump | gzip | gcloud storage cp
#######################################
echo "Streaming pg_dump | gzip | gcloud storage cp -> ${GCS_URI}"
# pg_dump flag rationale (Cloud SQL `import sql` requirements):
#   --format=plain          Cloud SQL `import sql` only accepts plain SQL
#                           text (gzipped is fine). Custom/directory formats
#                           require `pg_restore` and are not supported.
#   --encoding=UTF8         Forces UTF-8 in the dump regardless of source
#                           database encoding; matches Cloud SQL default.
#   --no-owner              Strips `ALTER ... OWNER TO ...` lines. Cloud SQL
#                           does not let you create the original RDS roles,
#                           so OWNER assignments would error out the import.
#   --no-privileges         Strips GRANT/REVOKE lines for the same reason.
#   --quote-all-identifiers Defensive: avoids reserved-word collisions if the
#                           target's PG version reserves new keywords.
#
# PGPASSWORD is read by libpq for the connection; it is scoped to this single
# command invocation (not exported to the rest of the script's environment).
#
# The pipeline:
#   pg_dump emits SQL on stdout
#     │
#     ▼
#   gzip -c compresses stdin -> stdout
#     │
#     ▼
#   `gcloud storage cp -` reads stdin and uploads it as the object at GCS_URI
#
# With `set -o pipefail` (already on), if pg_dump or gzip fail, the whole
# pipeline exits non-zero and `set -e` aborts the script BEFORE we try to
# import a half-written object.
set -o pipefail
PGPASSWORD="${SOURCE_DB_PASSWORD}" "${PG_DUMP_BIN}" \
  --host="${SOURCE_HOST}" \
  --port="${SOURCE_PORT}" \
  --username="${SOURCE_DB_USER}" \
  --dbname="${SOURCE_DB}" \
  --format=plain \
  --encoding=UTF8 \
  --no-owner \
  --no-privileges \
  --quote-all-identifiers \
  | gzip -c \
  | gcloud --project "${GCP_PROJECT_ID}" storage cp - "${GCS_URI}"

# Sanity-check that something landed in GCS (size + generation are printed).
echo "Verifying uploaded object"
gcloud --project "${GCP_PROJECT_ID}" storage ls -l "${GCS_URI}"

#######################################
# Cloud SQL import
#######################################
# `gcloud sql import sql` runs server-side on Cloud SQL. It reads the gzipped
# dump from GCS_URI and replays it into TARGET_DB. The Cloud SQL service
# agent (p<project-number>-...@gcp-sa-cloud-sql.iam.gserviceaccount.com) must
# have read access to the bucket — see the IAM note in the header.
echo "Starting Cloud SQL import"
if [[ "${IMPORT_ASYNC}" == "true" ]]; then
  # Async path: return immediately with an operation id the user can poll.
  OP_ID="$(gcloud --project "${GCP_PROJECT_ID}" sql import sql "${TARGET_CLOUDSQL_INSTANCE}" "${GCS_URI}" --database="${TARGET_DB}" --async --format='value(name)')"
  echo "Import started asynchronously. Operation: ${OP_ID}"
  echo "Track with: gcloud --project ${GCP_PROJECT_ID} sql operations describe ${OP_ID}"
else
  # Sync path: block until import succeeds or fails. `--quiet` suppresses the
  # interactive y/N confirmation prompt.
  gcloud --project "${GCP_PROJECT_ID}" sql import sql "${TARGET_CLOUDSQL_INSTANCE}" "${GCS_URI}" --database="${TARGET_DB}" --quiet
  echo "Import completed successfully"
fi

echo "Done"
echo "GCS object: ${GCS_URI}"
