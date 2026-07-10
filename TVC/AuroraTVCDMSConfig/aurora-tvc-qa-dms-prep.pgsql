-- =============================================================================
-- aurora-tvc-qa-dms-prep.sql
-- -----------------------------------------------------------------------------
-- In-database prep for a GCP Database Migration Service (DMS) continuous
-- (CDC) migration from Aurora Postgres to CloudSQL Postgres.
--
--   Source AWS cluster : tvc-qa   (us-east-1, Aurora Postgres)
--   Destination GCP    : CloudSQL Postgres  tvc-qa  (us-east4)
--   DMS user           : root   (the current Aurora master user)
--   DMS migration job  : tvc-qa-aurora  (vz-inscape-portfolio-qa / us-east4)
--
-- WHEN TO RUN
-- -----------
-- Run this AFTER `aurora-tvc-qa-dms-prep.sh` has completed and the writer is
-- back "available". This file assumes:
--   * rds.logical_replication is already ON
--   * shared_preload_libraries already contains pglogical
--   * you are connecting AS the AWS master user (`root`) over TLS
--
-- Connect with (verifies the RDS CA in ~/Documents/rds-us-east-1-bundle.pem):
   psql "host=tvc-qa.cujpo2r0mujo.us-east-1.rds.amazonaws.com \
         port=5432 dbname=postgres user=root \
         sslmode=verify-full \
         sslrootcert=/Users/michael.dspain/Documents/rds-us-east-1-bundle.pem"
--
-- WHAT THIS SCRIPT DOES
-- ---------------------
--   1. Grants the DMS user the two RDS-managed roles it needs
--      (rds_replication for logical decoding, rds_superuser so pglogical can
--      manage its schema and create logical slots).
--   2. Prints a set of `SHOW` sanity checks the operator can eyeball to
--      confirm the cluster-side prep landed correctly.
--   3. For each database being migrated:
--        - creates the pglogical extension
--        - hands the pglogical schema to the DMS user
--        - grants USAGE + SELECT on every user schema and future objects
--   4. Emits an audit query listing tables that DMS CDC cannot replicate as-is
--      (no PRIMARY KEY and no REPLICA IDENTITY FULL). Fix these before you
--      start the job or the job will fail during CDC apply.
--   5. Confirms pglogical is loaded and has no lingering subscriptions.
--
-- HOW TO RUN THE PER-DB BLOCK FOR EVERY DATABASE
-- ----------------------------------------------
-- The per-database block ends with `SELECT * FROM pglogical.show_subscription_status();`
-- Copy that block, `\c <next_db>`, and re-execute for each database the DMS
-- job will include. Databases the DMS job is NOT migrating do not need it.
--
-- ROLLBACK
-- --------
--   REVOKE rds_replication, rds_superuser FROM root;
--   DROP EXTENSION IF EXISTS pglogical;          -- inside each DB
-- WARNING: dropping pglogical destroys any active logical replication slots
-- created inside that DB. Do not run rollback while the migration job is
-- running.
-- =============================================================================


-- =============================================================================
-- SECTION 1 -- Cluster-wide grants (run ONCE, in any database)
-- =============================================================================
-- rds_replication
--   RDS-managed role granting the REPLICATION attribute equivalent that AWS
--   otherwise blocks on managed clusters. Required for the DMS user to open
--   a logical replication connection.
--
-- rds_superuser
--   Aurora's proxy for SUPERUSER. pglogical needs elevated privileges to
--   create replication slots, register nodes, and read all schemas without
--   per-object grants. Aurora does NOT expose real SUPERUSER; rds_superuser
--   is the AWS-supplied equivalent.
-- -----------------------------------------------------------------------------
GRANT rds_replication TO root;
GRANT rds_superuser   TO root;

-- -----------------------------------------------------------------------------
-- Sanity checks -- run and eyeball the output before continuing.
-- Any deviation means the parameter-group patch didn't land; stop and re-run
-- `aurora-tvc-qa-dms-prep.sh`.
-- -----------------------------------------------------------------------------
SHOW wal_level;                        -- expect: logical
SHOW rds.logical_replication;          -- expect: on
SHOW shared_preload_libraries;         -- expect: value that contains "pglogical"


-- =============================================================================
-- SECTION 2 -- Per-database prep (REPEAT THIS SECTION FOR EACH MIGRATED DB)
-- =============================================================================
-- Change the target database with \c before re-running. The block below is
-- written for the `postgres` maintenance DB as an example; substitute your
-- application database name(s).
--
-- IMPORTANT: psql meta-commands (like \c) do NOT support inline -- comments.
-- The whole rest of the line is parsed as extra \connect arguments. Keep the
-- \c on its own line.
-- -----------------------------------------------------------------------------
\c postgres

-- Install pglogical. Requires the shared library to already be preloaded via
-- shared_preload_libraries; if this errors with "could not load ... pglogical"
-- then the writer was not rebooted after the parameter-group change.
CREATE EXTENSION IF NOT EXISTS pglogical;

-- Hand ownership + access of the pglogical schema to the DMS user so it can
-- create replication sets, nodes, and subscriptions during CDC bring-up.
ALTER SCHEMA pglogical OWNER TO root;
GRANT USAGE ON SCHEMA pglogical TO root;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO root;

-- -----------------------------------------------------------------------------
-- Grant DMS the read access it needs on every user schema.
--   * USAGE on the schema  -> lets it name-resolve inside the schema
--   * SELECT on tables     -> lets it copy rows during the initial snapshot
--   * SELECT on sequences  -> lets it capture sequence values
--   * ALTER DEFAULT PRIVS  -> makes future tables/sequences readable too, so
--                             DDL added after prep does not silently break
--                             the migration.
-- We loop over every user schema (skipping system + pglogical) so we do not
-- have to name each one, and so this script is portable across DBs.
-- -----------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog','information_schema','pglogical')
      AND nspname NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO root', s);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO root', s);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO root', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO root', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO root', s);
  END LOOP;
END$$;

-- -----------------------------------------------------------------------------
-- CDC readiness audit
-- -----------------------------------------------------------------------------
-- pglogical (and therefore DMS) needs a way to uniquely identify every row it
-- replicates. Postgres derives that identity from:
--     PRIMARY KEY                            -> best; nothing to do
--     REPLICA IDENTITY FULL on the table     -> works but heavy: every UPDATE
--                                               ships the entire OLD row.
--     REPLICA IDENTITY USING INDEX <idx>     -> works if the index is UNIQUE
--                                               and NOT NULL on all columns.
-- Tables with none of the above CANNOT be CDC-replicated; DMS will error out.
--
-- relreplident values:
--     d = default (PRIMARY KEY)
--     n = nothing   <-- broken for CDC
--     f = full
--     i = index
-- The query below lists every user table with NO primary key so you can pick
-- a remediation for each one before starting the job.
-- -----------------------------------------------------------------------------
SELECT n.nspname AS schema,
       c.relname AS table,
       c.relreplident AS replica_identity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pglogical')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  )
ORDER BY 1,2;
-- Remediation for each row above (pick one, in preference order):
--   1) ALTER TABLE <schema>.<table> ADD PRIMARY KEY (<cols>);
--   2) ALTER TABLE <schema>.<table> REPLICA IDENTITY USING INDEX <unique_idx>;
--   3) ALTER TABLE <schema>.<table> REPLICA IDENTITY FULL;   -- last resort

-- -----------------------------------------------------------------------------
-- Final health check: confirm pglogical is installed AND that there are no
-- leftover pglogical nodes/subscriptions from earlier attempts.
--
-- IMPORTANT: We deliberately do NOT call pglogical.show_subscription_status()
-- here. That function raises
--     "current database is not configured as pglogical node"
-- on any DB where a pglogical node has not been created -- which is the
-- expected state on a fresh source. GCP DMS creates the pglogical node itself
-- when the migration job starts; do not create it manually or DMS will
-- collide with it.
--
-- If either of the queries below returns rows, drop the stale objects before
-- starting the DMS job:
--     SELECT pglogical.drop_subscription(sub_name := '<sub>');
--     SELECT pglogical.drop_node(node_name := '<node>');
-- -----------------------------------------------------------------------------
-- 1. pglogical extension is installed in this DB
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pglogical';

-- 2. No leftover pglogical nodes in this DB (expect 0 rows on a fresh source)
SELECT node_id, node_name
FROM pglogical.node;

-- 3. No leftover local subscriptions in this DB (expect 0 rows on a fresh source)
SELECT sub_id, sub_name, sub_enabled
FROM pglogical.subscription;
