#!/bin/bash
set -euo pipefail

################################################################################
# Aurora to AlloyDB Migration Script
# Backs up Aurora cluster, transfers to GCS, and imports into AlloyDB
################################################################################

# ============================================================================
# 1. CONFIGURATION
# ============================================================================

AWS_PROFILE='inscape-production-us-1-inscape-aws-ops'
AWS_REGION='us-east-1'
AURORA_CLUSTER='tvc-development-cluster'
S3_BUCKET='tvc-db-dump'
GCS_BUCKET='gs://tvc-db-dump'
GCP_PROJECT='vz-inscape-portfolio-dev'
ALLOYDB_CLUSTER='tvc-development-cluster'
ALLOYDB_REGION='us-east4'
ALLOYDB_USER='root'
ALLOYDB_HOST='10.234.255.248'  # PSC private IP
ALLOYDB_PORT='5432'

# Aurora credentials (set these before running)
AURORA_USER='root'
AURORA_PASSWORD="${AURORA_PASSWORD:-}"  # Pass as env var: export AURORA_PASSWORD='...'

if [ -z "$AURORA_PASSWORD" ]; then
  echo "ERROR: AURORA_PASSWORD environment variable not set"
  echo "Usage: export AURORA_PASSWORD='your_password' && $0"
  exit 1
fi

# ============================================================================
# 2. AUTH & PREP
# ============================================================================

echo "=== Step 1: Authenticating with AWS and GCP ==="
export AWS_PROFILE
gcloud config set project "$GCP_PROJECT" >/dev/null
echo "✓ AWS and GCP authenticated"

# ============================================================================
# 3. GET AURORA ENDPOINT
# ============================================================================

echo "=== Step 2: Resolving Aurora cluster endpoint ==="
export PGHOST=$(aws rds describe-db-clusters \
  --region "$AWS_REGION" \
  --db-cluster-identifier "$AURORA_CLUSTER" \
  --query 'DBClusters[0].Endpoint' \
  --output text)

export PGPORT=$(aws rds describe-db-clusters \
  --region "$AWS_REGION" \
  --db-cluster-identifier "$AURORA_CLUSTER" \
  --query 'DBClusters[0].Port' \
  --output text)

export PGUSER="$AURORA_USER"
export PGPASSWORD="$AURORA_PASSWORD"

echo "Aurora endpoint: $PGHOST:$PGPORT"

# ============================================================================
# 4. LIST DATABASES TO BACKUP
# ============================================================================

echo "=== Step 3: Getting database list from Aurora ==="
DBS=$(psql "host=$PGHOST port=$PGPORT user=$PGUSER dbname=postgres sslmode=require" -Atc "
select datname from pg_database
where datistemplate=false
  and datallowconn=true
  and datname not in ('rdsadmin');
")

echo "Databases found:"
echo "$DBS"

# ============================================================================
# 5. DUMP AURORA DATABASES TO S3
# ============================================================================

echo "=== Step 4: Dumping Aurora databases as SQL to S3 ==="
TS=$(date +%Y%m%d-%H%M%S)
DUMP_PREFIX="s3://$S3_BUCKET/$AURORA_CLUSTER/$TS"

for db in $DBS; do
  echo "Dumping $db ..."
  pg_dump "host=$PGHOST port=$PGPORT user=$PGUSER dbname=$db sslmode=require" \
    --format=plain \
    --no-owner \
    --no-acl \
    | gzip \
    | aws s3 cp - "$DUMP_PREFIX/${db}.sql.gz"
done

# Create manifest
printf "%s\n" $DBS | aws s3 cp - "$DUMP_PREFIX/DATABASES.txt"
echo "✓ Dumps uploaded to $DUMP_PREFIX"

# ============================================================================
# 6. COPY FROM S3 TO GCS
# ============================================================================

echo "=== Step 5: Copying from S3 to GCS ==="
GCS_PREFIX="$GCS_BUCKET/$AURORA_CLUSTER/$TS"

gcloud storage cp --recursive "s3://$S3_BUCKET/$AURORA_CLUSTER/$TS/" "$GCS_PREFIX/"

# Verify counts match
aws_count=$(aws s3 ls "s3://$S3_BUCKET/$AURORA_CLUSTER/$TS/" --recursive | wc -l | tr -d ' ')
gcs_count=$(gcloud storage ls --recursive "$GCS_PREFIX/**" | wc -l | tr -d ' ')

echo "AWS objects: $aws_count"
echo "GCS objects: $gcs_count"

if [ "$aws_count" -ne "$gcs_count" ]; then
  echo "ERROR: Object count mismatch between S3 and GCS"
  exit 1
fi

echo "✓ Files copied to $GCS_PREFIX"

# ============================================================================
# 7. FIX PMM DATABASE (remove incompatible pg_stat_statements views)
# ============================================================================

echo "=== Step 6: Fixing PMM database for AlloyDB compatibility ==="

# Check if pmm exists in the dump
if printf "%s\n" $DBS | grep -q "^pmm$"; then
  PMM_FILE="$GCS_PREFIX/$TS/pmm.sql.gz"
  PMM_FIXED="$GCS_PREFIX/$TS/pmm.fixed.sql.gz"
  
  # Download
  gcloud storage cp "$PMM_FILE" /tmp/pmm.sql.gz
  gunzip -c /tmp/pmm.sql.gz > /tmp/pmm.sql
  
  # Remove problematic PMM objects that don't work on PG17
  sed -i '' '/^CREATE FUNCTION pmm\.get_pg_stat_statements()/,/^$/d' /tmp/pmm.sql || true
  sed -i '' '/^CREATE VIEW pmm\.pg_stat_statements AS/,/;$/d' /tmp/pmm.sql || true
  
  # Repack and upload fixed version
  gzip -c /tmp/pmm.sql > /tmp/pmm.fixed.sql.gz
  gcloud storage cp /tmp/pmm.fixed.sql.gz "$PMM_FIXED"
  
  # Update reference for import
  PMM_IMPORT_URI="$PMM_FIXED"
  echo "✓ PMM database fixed"
else
  PMM_IMPORT_URI=""
fi

# ============================================================================
# 8. GRANT PERMISSIONS ON ALLOYDB
# ============================================================================

echo "=== Step 7: Granting permissions on AlloyDB databases ==="

# This requires connection to AlloyDB from a VPC-reachable host
# For now, we create a script that can be run separately
GRANT_SCRIPT="/tmp/alloydb-grants.sql"

cat > "$GRANT_SCRIPT" << 'EOF'
-- Grant permissions for all target databases
DO $$
DECLARE
    db_name text;
    dbs text[] := ARRAY['app_whitelist', 'dai_demapping', 'dai_engine_map', 'new_dai_engine_map_temp', 'optout', 'pmm', 'postgres', 'test_dai_engine_map', 'tvevents', 'tvlocation'];
BEGIN
    FOREACH db_name IN ARRAY dbs LOOP
        BEGIN
            EXECUTE 'ALTER DATABASE ' || quote_ident(db_name) || ' OWNER TO root';
            EXECUTE 'GRANT CONNECT, CREATE, TEMP ON DATABASE ' || quote_ident(db_name) || ' TO root';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error on database %: %', db_name, SQLERRM;
        END;
    END LOOP;
END $$;

-- Grant schema permissions for all databases
DO $$
DECLARE
    db_name text;
    dbs text[] := ARRAY['app_whitelist', 'dai_demapping', 'dai_engine_map', 'new_dai_engine_map_temp', 'optout', 'pmm', 'postgres', 'test_dai_engine_map', 'tvevents', 'tvlocation'];
BEGIN
    FOREACH db_name IN ARRAY dbs LOOP
        BEGIN
            EXECUTE 'ALTER SCHEMA public OWNER TO root' USING db_name;
            EXECUTE 'GRANT USAGE, CREATE ON SCHEMA public TO root' USING db_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error on schema for %: %', db_name, SQLERRM;
        END;
    END LOOP;
END $$;
EOF

echo "Grant script created at $GRANT_SCRIPT"
echo "Run this on AlloyDB from a VPC-reachable host:"
echo "  psql -h $ALLOYDB_HOST -U $ALLOYDB_USER -d postgres -f $GRANT_SCRIPT"

# ============================================================================
# 9. IMPORT INTO ALLOYDB
# ============================================================================

echo "=== Step 8: Importing databases into AlloyDB ==="

# Build import commands
for db in $DBS; do
  if [ "$db" = "pmm" ] && [ -n "$PMM_IMPORT_URI" ]; then
    # Use fixed pmm
    uri=$(echo "$PMM_IMPORT_URI" | sed 's|gs://||')
    uri="gs://$uri"
  else
    uri="$GCS_PREFIX/$TS/${db}.sql.gz"
  fi
  
  echo ""
  echo "Importing $db from $uri"
  gcloud alloydb clusters import "$ALLOYDB_CLUSTER" \
    --region="$ALLOYDB_REGION" \
    --database="$db" \
    --user="$ALLOYDB_USER" \
    --gcs-uri="$uri" \
    --sql \
    --async
done

echo ""
echo "✓ All import operations started (async)"
echo ""
echo "Monitor progress with:"
echo "  gcloud alloydb operations list --region=$ALLOYDB_REGION --format='table(name,done,error)'"

# ============================================================================
# 10. SUMMARY
# ============================================================================

echo ""
echo "================================================================================"
echo "MIGRATION COMPLETE"
echo "================================================================================"
echo ""
echo "Summary:"
echo "  Aurora Cluster:   $AURORA_CLUSTER ($PGHOST)"
echo "  S3 Location:      s3://$S3_BUCKET/$AURORA_CLUSTER/$TS/"
echo "  GCS Location:     $GCS_PREFIX/"
echo "  AlloyDB Cluster:  $ALLOYDB_CLUSTER (region: $ALLOYDB_REGION)"
echo "  Databases:        $(echo $DBS | wc -w)"
echo ""
echo "Next steps:"
echo "  1. Run grants on AlloyDB:"
echo "     psql -h $ALLOYDB_HOST -U $ALLOYDB_USER -d postgres -f $GRANT_SCRIPT"
echo ""
echo "  2. Monitor import operations:"
echo "     gcloud alloydb operations list --region=$ALLOYDB_REGION"
echo ""
echo "  3. Verify imports completed successfully"
echo ""
echo "================================================================================"
