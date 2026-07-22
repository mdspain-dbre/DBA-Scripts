#!/usr/bin/env bash
# =============================================================================
# aurora-tvc-qa-dms-install-perdb.sh
# -----------------------------------------------------------------------------
# Iterates every user database on the source Aurora Postgres cluster and runs
# aurora-tvc-qa-dms-perdb.pgsql against each one. Idempotent -- safe to re-run.
#
# What "user database" means here:
#   - datistemplate = false
#   - excludes rdsadmin (AWS-managed; DMS cannot touch it)
#   NOTE: the `postgres` maintenance DB IS included -- if it has no user
#   tables the CREATE EXTENSION + grants are still harmless and idempotent,
#   and any stray app schema in it will get picked up.
#
# Prompts once for the password (or supply via PGPASSWORD env var).
#
# USAGE
#   PGPASSWORD='<root pw>' ./aurora-tvc-qa-dms-install-perdb.sh
#   # or interactively (prompted per DB unless PGPASSWORD is set):
#   ./aurora-tvc-qa-dms-install-perdb.sh
# =============================================================================
set -Eeuo pipefail

HOST="tvc-qa.cujpo2r0mujo.us-east-1.rds.amazonaws.com"
PORT=5432
USER="root"
CA="/Users/michael.dspain/Documents/rds-us-east-1-bundle.pem"
PERDB_SQL="$(dirname "$0")/aurora-tvc-qa-dms-perdb.pgsql"

if [[ ! -f "$PERDB_SQL" ]]; then
  echo "ERROR: $PERDB_SQL not found" >&2
  exit 1
fi

conn() {
  # $1 = dbname
  echo "host=${HOST} port=${PORT} dbname=$1 user=${USER} sslmode=verify-full sslrootcert=${CA}"
}

echo "=== Discovering user databases on ${HOST} ==="
DBS=$(psql "$(conn postgres)" -tAc "
  SELECT datname
  FROM pg_database
  WHERE datistemplate = false
    AND datname NOT IN ('rdsadmin')
  ORDER BY 1;")

if [[ -z "$DBS" ]]; then
  echo "No user databases found. Nothing to do."
  exit 0
fi

echo "Will run $PERDB_SQL against:"
printf '  - %s\n' $DBS
echo

FAILED=()
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  echo "=== [$db] applying pglogical + grants ==="
  if psql --set ON_ERROR_STOP=1 "$(conn "$db")" -f "$PERDB_SQL"; then
    echo "=== [$db] OK ==="
  else
    echo "=== [$db] FAILED (continuing) ===" >&2
    FAILED+=("$db")
  fi
  echo
done <<< "$DBS"

if (( ${#FAILED[@]} > 0 )); then
  echo "Databases that failed: ${FAILED[*]}" >&2
  exit 1
fi
echo "All databases processed successfully."
