#!/usr/bin/env bash
# Pull RDS Proxy CloudWatch metrics for the incident window.
# Namespace: AWS/RDS, dimension: ProxyName
set -euo pipefail

PROXY="account-db-prod-proxy-us-west-2"
REGION="us-west-2"
START="2026-09-11T22:00:00Z"
END="2026-09-12T01:00:00Z"
PERIOD=60
OUTDIR="$(dirname "$0")/metrics"
mkdir -p "$OUTDIR"

METRICS=(
  ClientConnections
  ClientConnectionsReceived
  ClientConnectionsClosed
  ClientConnectionsSetupSucceeded
  ClientConnectionsSetupFailedAuth
  DatabaseConnections
  DatabaseConnectionsCurrentlyBorrowed
  DatabaseConnectionsCurrentlySessionPinned
  DatabaseConnectionsBorrowLatency
  DatabaseConnectionRequests
  DatabaseConnectionRequestsWithTLS
  MaxDatabaseConnectionsAllowed
  QueryDatabaseResponseLatency
  QueryRequests
  QueryRequestsNoTLS
  QueryRequestsWithTLS
)

for m in "${METRICS[@]}"; do
  echo "==> $m"
  aws --region "$REGION" cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name "$m" \
    --dimensions Name=ProxyName,Value="$PROXY" \
    --start-time "$START" \
    --end-time   "$END" \
    --period "$PERIOD" \
    --statistics Average Maximum Minimum Sum \
    --output json > "$OUTDIR/${m}.json"
done

echo "Done. Metric JSON in $OUTDIR"
