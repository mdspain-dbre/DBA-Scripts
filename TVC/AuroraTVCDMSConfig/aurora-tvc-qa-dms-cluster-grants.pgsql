-- =============================================================================
-- aurora-tvc-qa-dms-cluster-grants.pgsql
-- -----------------------------------------------------------------------------
-- Cluster-wide (one-shot) grants + sanity checks for a GCP Database Migration
-- Service (DMS) continuous (CDC) migration from Aurora Postgres to CloudSQL.
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
--   psql "host=tvc-qa.cujpo2r0mujo.us-east-1.rds.amazonaws.com \
--         port=5432 dbname=postgres user=root \
--         sslmode=verify-full \
--         sslrootcert=/Users/michael.dspain/Documents/rds-us-east-1-bundle.pem"
--
-- Run ONCE against any database on the cluster (roles are cluster-scoped).
-- Per-database pglogical install + grants live in aurora-tvc-qa-dms-perdb.pgsql
-- and are fanned out to every user DB by aurora-tvc-qa-dms-install-perdb.sh.
--
-- ROLLBACK
--   REVOKE rds_replication, rds_superuser FROM root;
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
GRANT rds_replication TO root;
GRANT rds_superuser   TO root;

-- Sanity checks -- run and eyeball the output before continuing.
-- Any deviation means the parameter-group patch didn't land; stop and re-run
-- `aurora-tvc-qa-dms-prep.sh`.
SHOW wal_level;                        -- expect: logical
SHOW rds.logical_replication;          -- expect: on
SHOW shared_preload_libraries;         -- expect: value that contains "pglogical"
