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
#     the RDS CA bundle (~/Documents/rds-us-east-1-bundle.pem) and
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
CLUSTER_ID="tvc-qa-cluster"
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
#   - describe-db-cluster-parameters is paginated; a single parameter name can
#     appear across pages, so --no-paginate keeps us on the first page and
#     [0].ParameterValue picks a single value (not a projection list).
#   - --output text prints the literal string "None" when the value is null;
#     we treat that as empty below.
CURRENT_SPL=$(aws rds describe-db-cluster-parameters --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --no-paginate \
  --query "Parameters[?ParameterName=='shared_preload_libraries'] | [0].ParameterValue" \
  --output text)
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

# Apply the two required parameters.
echo "=== Patching cluster parameter group: $CLUSTER_PG ==="
aws rds modify-db-cluster-parameter-group \
  --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --parameters \
    "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" \
    "ParameterName=shared_preload_libraries,ParameterValue=${NEW_SPL},ApplyMethod=pending-reboot"

# Show the pending state so the operator can confirm.
echo "=== Pending changes ==="
aws rds describe-db-cluster-parameters --region "$REGION" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" \
  --query "Parameters[?ParameterName=='rds.logical_replication' || ParameterName=='shared_preload_libraries'].[ParameterName,ParameterValue,ApplyMethod]" \
  --output table

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
echo "Reboot complete. Next: run aurora-tvc-qa-dms-prep.pgsql against each source DB."
