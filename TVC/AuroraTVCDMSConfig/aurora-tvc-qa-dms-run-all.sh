#!/usr/bin/env bash
# =============================================================================
# aurora-tvc-qa-dms-run-all.sh
# -----------------------------------------------------------------------------
# One-shot orchestrator for the entire Aurora Postgres -> GCP DMS prep.
# Executes the three phases in order and halts on any failure:
#
#   1. AWS side  : aurora-tvc-qa-dms-prep.sh
#                    - patches the cluster parameter group
#                    - reboots the writer
#
#   2. Cluster   : psql -f aurora-tvc-qa-dms-cluster-grants.pgsql
#                    - GRANT rds_replication / rds_superuser TO root
#                    - SHOW sanity checks
#
#   3. Per-DB    : aurora-tvc-qa-dms-install-perdb.sh
#                    - loops every user DB (excl. rdsadmin)
#                    - CREATE EXTENSION pglogical + schema grants
#                    - CDC-blocking-table audit
#
# PREREQUISITES
#   - AWS CLI v2 authenticated for RDS in us-east-1 (see prep.sh header for the
#     IAM actions required).
#   - psql on PATH.
#   - RDS CA bundle at /Users/michael.dspain/Documents/tvc-stage-global-bundle.pem
#     (edit CA below if it lives elsewhere).
#   - Aurora master password for `root` -- provide via PGPASSWORD env var, or
#     via the local `secrets.txt` file (line: `Root = '<pw>'`). PGPASSWORD wins
#     if already exported; otherwise the script reads secrets.txt.
#
# USAGE
#   ./aurora-tvc-qa-dms-run-all.sh                          # reads secrets.txt
#   PGPASSWORD='<root pw>' ./aurora-tvc-qa-dms-run-all.sh   # env override
#
# NOTE: Phase 1 (AWS parameter group + reboot) does NOT need PGPASSWORD; it
# uses AWS CLI credentials. The password is only needed for phases 2-3.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST="tvc-staging-cluster.cluster-cujpo2r0mujo.us-east-1.rds.amazonaws.com"
PORT=5432
USER="root"
CA="/Users/michael.dspain/Documents/tvc-stage-global-bundle.pem"

PREP_SH="${HERE}/aurora-tvc-qa-dms-prep.sh"
CLUSTER_SQL="${HERE}/aurora-tvc-qa-dms-cluster-grants.pgsql"
PERDB_SH="${HERE}/aurora-tvc-qa-dms-install-perdb.sh"

for f in "$PREP_SH" "$CLUSTER_SQL" "$PERDB_SH"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done
[[ -f "$CA" ]] || { echo "ERROR: RDS CA bundle not found at $CA" >&2; exit 1; }

# --- password: read from secrets.txt if not already exported ---------------
if [[ -z "${PGPASSWORD:-}" ]]; then
  SECRETS_FILE="${HERE}/secrets.txt"
  [[ -f "$SECRETS_FILE" ]] || { echo "ERROR: secrets file not found: $SECRETS_FILE" >&2; exit 1; }
  PGPASSWORD=$(sed -nE "s/^[[:space:]]*Root[[:space:]]*=[[:space:]]*['\"]?([^'\"]+)['\"]?.*/\1/p" "$SECRETS_FILE" | head -1)
  [[ -n "$PGPASSWORD" ]] || { echo "ERROR: 'Root = ...' not found in $SECRETS_FILE" >&2; exit 1; }
  export PGPASSWORD
fi

banner() {
  echo
  echo "############################################################"
  echo "# $*"
  echo "############################################################"
}

# --- Phase 1: AWS-side param patch + reboot --------------------------------
banner "Phase 1/3: AWS cluster parameter patch + writer reboot"
bash "$PREP_SH"

# --- Phase 2: cluster-wide grants (once) -----------------------------------
banner "Phase 2/3: Cluster-wide grants + sanity checks"
psql --set ON_ERROR_STOP=1 \
  "host=${HOST} port=${PORT} dbname=postgres user=${USER} \
   sslmode=verify-full sslrootcert=${CA}" \
  -f "$CLUSTER_SQL"

# --- Phase 3: per-database pglogical install + grants ---------------------
banner "Phase 3/3: Per-database pglogical install + grants + audit"
bash "$PERDB_SH"

banner "Done. Review any CDC-blocking tables printed above, then start the DMS job."
