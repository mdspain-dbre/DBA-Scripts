#!/usr/bin/env bash
# =============================================================================
# aurora-tvc-qa-dms-prep.sh
# -----------------------------------------------------------------------------
# Minimal Aurora PostgreSQL cluster parameter-group patch for a GCP Database
# Migration Service (DMS) continuous (CDC) migration.
#
#   Source AWS cluster : tvc-qa   (us-east-1, Aurora Postgres)
#   Destination GCP    : CloudSQL Postgres  tvc-qa  (us-east4)
#   DMS migration job  : tvc-qa-aurora   in vz-inscape-portfolio-qa / us-east4
#
# WHAT THIS SCRIPT CHANGES
# ------------------------
# Only the two settings DMS actually requires:
#
#   rds.logical_replication          -> 1
#       Aurora meta-parameter. Turns on wal_level=logical so pglogical can
#       decode WAL. Without this, CDC never starts.
#
#   shared_preload_libraries         -> merge in "pglogical"
#       Preloads the pglogical shared library at postmaster start so
#       CREATE EXTENSION pglogical can run inside individual databases.
#       Existing entries are preserved.
#
# Both are STATIC on Aurora (pending-reboot), so the script reboots the
# writer at the end.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT CHANGE
# ---------------------------------------------
# - max_replication_slots / max_wal_senders / max_worker_processes
#     Aurora defaults are already enough for a single DMS migration
#     (1 slot + 1 sender + ~4 workers). Not touched.
# - wal_sender_timeout
#     Left at Aurora default (60s). Setting it to 0 would DISABLE
#     dead-connection detection on the WAL sender, which risks a stuck
#     replication slot and unbounded WAL retention if DMS ever loses
#     the TCP session silently.
# - rds.force_ssl
#     Left at 1. The DMS source connection profile is configured with
#     the RDS CA bundle (~/Documents/tvc-stage-global-bundle.pem) and
#     connects over TLS.
#
# PREREQUISITES
# -------------
# - AWS CLI v2 on PATH with credentials for an IAM principal that has:
#       rds:DescribeDBClusters
#       rds:DescribeDBClusterParameters
#       rds:ModifyDBClusterParameterGroup
#       rds:RebootDBInstance
# - The cluster MUST be on a CUSTOM cluster parameter group. Defaults
#   (default.aurora-postgresql*) are immutable; this script refuses to run
#   against one.
# - A short maintenance window (writer reboot at the end, ~10-60s).
#
# ROLLBACK
# --------
#   aws rds modify-db-cluster-parameter-group \
#       --region us-east-1 \
#       --db-cluster-parameter-group-name <CLUSTER_PG> \
#       --parameters \
#           ParameterName=rds.logical_replication,ParameterValue=0,ApplyMethod=pending-reboot \
#           ParameterName=shared_preload_libraries,ParameterValue=<original>,ApplyMethod=pending-reboot
#   then reboot the writer again.
#
# USAGE
# -----
#   ./aurora-tvc-qa-dms-prep.sh
# =============================================================================

set -Eeuo pipefail

# --- config -----------------------------------------------------------------
CLUSTER_ID="tvc-staging-cluster"
CLUSTER_PG=""                 # blank = auto-discover
REGION="us-east-1"
# ---------------------------------------------------------------------------

# Discover attached cluster parameter group if not pinned above.
if [[ -z "$CLUSTER_PG" ]]; then
  CLUSTER_PG=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].DBClusterParameterGroup' --output text)
  echo "Discovered cluster parameter group: $CLUSTER_PG"
fi

# Refuse to touch AWS-managed default groups (they are immutable).
if [[ "$CLUSTER_PG" == default.* ]]; then
  echo "ERROR: cluster is on $CLUSTER_PG (an AWS-managed default group)." >&2
  echo "Create a custom cluster parameter group and attach it before running this." >&2
  exit 1
fi

# Merge pglogical into shared_preload_libraries without clobbering existing entries.
# Notes on the query:
#   - describe-db-cluster-parameters is paginated (~100 params/page, ~460 total
#     on a modern Aurora Postgres param group). shared_preload_libraries is NOT
#     on page 1.
#   - We CANNOT use server-side --query here: JMESPath runs per response page,
#     and `[0].ParameterValue` on pages that don't contain the param returns
#     `None`, which --output text concatenates into "NoneNoneNone<value>".
#     Passing --no-paginate to "fix" that silently drops pages 2+ and hides
#     the real value entirely -- which then wipes existing preloaded libraries
#     (pg_stat_statements, etc.) on the next reboot.
#   - So: fetch full JSON with pagination on, parse client-side with python3.
CURRENT_SPL=$(aws rds describe-db-cluster-parameters --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --output json \
  | python3 -c '
import json, sys
params = json.load(sys.stdin).get("Parameters", [])
for p in params:
    if p.get("ParameterName") == "shared_preload_libraries":
        print(p.get("ParameterValue") or "")
        break
')
# Collapse any accidental multi-line text and strip surrounding whitespace.
CURRENT_SPL=$(printf '%s' "$CURRENT_SPL" | tr -d '\n\r' | awk '{$1=$1};1')
if [[ "$CURRENT_SPL" == "None" || -z "$CURRENT_SPL" ]]; then
  NEW_SPL="pglogical"
elif [[ ",$CURRENT_SPL," == *",pglogical,"* ]]; then
  NEW_SPL="$CURRENT_SPL"
else
  NEW_SPL="${CURRENT_SPL},pglogical"
fi
echo "shared_preload_libraries: '$CURRENT_SPL' -> '$NEW_SPL'"

# --- Safety gate: confirm target account/cluster before any mutation. -------
# Prevents a stray AWS_PROFILE / default-creds mismatch from patching the
# wrong cluster in the wrong account.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
cat <<EOF

=== Confirm target before mutating ===
  AWS account : $ACCOUNT_ID
  Caller      : $CALLER_ARN
  Region      : $REGION
  Cluster     : $CLUSTER_ID
  ParamGroup  : $CLUSTER_PG
  Will set    : rds.logical_replication = 1  (pending-reboot)
                shared_preload_libraries = '$NEW_SPL'  (pending-reboot)
  Will then   : reboot the writer instance (cluster outage ~10-60s)

EOF
read -r -p "Type the cluster id ($CLUSTER_ID) to proceed: " CONFIRM
if [[ "$CONFIRM" != "$CLUSTER_ID" ]]; then
  echo "Aborted (confirmation did not match)." >&2
  exit 1
fi

# Apply the two required parameters.
# NOTE: we MUST use JSON syntax for --parameters here, not the CLI shorthand.
# Shorthand ("ParameterName=X,ParameterValue=Y,ApplyMethod=Z") treats every
# comma as a key separator, so a value like "pg_stat_statements,pglogical"
# is parsed as a list ['pg_stat_statements','pglogical'] and the API rejects
# it with "Invalid type for parameter ParameterValue ... valid types: str".
# NEW_SPL is passed through the environment to avoid quote-injection risk.
echo "=== Patching cluster parameter group: $CLUSTER_PG ==="
PARAMS_JSON=$(NEW_SPL="$NEW_SPL" python3 -c '
import json, os
print(json.dumps([
    {"ParameterName": "rds.logical_replication",  "ParameterValue": "1",                     "ApplyMethod": "pending-reboot"},
    {"ParameterName": "shared_preload_libraries", "ParameterValue": os.environ["NEW_SPL"], "ApplyMethod": "pending-reboot"},
]))
')
aws rds modify-db-cluster-parameter-group \
  --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --parameters "$PARAMS_JSON"

# Show the pending state so the operator can confirm.
# Same pagination caveat as above -- fetch full JSON, filter client-side.
echo "=== Pending changes ==="
aws rds describe-db-cluster-parameters --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --output json \
  | python3 -c '
import json, sys
wanted = {"rds.logical_replication", "shared_preload_libraries"}
params = json.load(sys.stdin).get("Parameters", [])
hits = [p for p in params if p.get("ParameterName") in wanted]
fmt = "  {:<28} {:<40} {}"
print(fmt.format("ParameterName", "ParameterValue", "ApplyMethod"))
print(fmt.format("-" * 28, "-" * 40, "-" * 12))
for p in hits:
    print(fmt.format(p["ParameterName"], p.get("ParameterValue", "") or "", p.get("ApplyMethod", "")))
'

# Reboot the writer to activate the pending-reboot parameters.
echo "=== Rebooting writer to apply pending-reboot params ==="
WRITER=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query "DBClusters[0].DBClusterMembers[?IsClusterWriter==\`true\`].DBInstanceIdentifier | [0]" \
  --output text)
echo "Writer: $WRITER"
aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$WRITER"

echo "Waiting for writer to become available..."
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$WRITER"
echo "Reboot complete."
echo "Next:"
echo "  1) psql ... -f aurora-tvc-qa-dms-cluster-grants.pgsql   (once, cluster-wide)"
echo "  2) ./aurora-tvc-qa-dms-install-perdb.sh                  (fans out perdb SQL)"
