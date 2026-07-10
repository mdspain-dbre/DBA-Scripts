-- =============================================================================
-- aurora-tvc-qa-dms-perdb.pgsql
-- -----------------------------------------------------------------------------
-- Per-database prep for GCP DMS from Aurora Postgres.
-- Invoked once per user DB by aurora-tvc-qa-dms-install-perdb.sh.
--
-- Does NOT call \c -- the caller connects to the target DB directly.
-- Safe to re-run: CREATE EXTENSION IF NOT EXISTS + idempotent grants.
-- =============================================================================

-- Install pglogical in the current database.
CREATE EXTENSION IF NOT EXISTS pglogical;

-- Hand ownership + access of the pglogical schema to the DMS user so it can
-- create replication sets, nodes, and subscriptions during CDC bring-up.
ALTER SCHEMA pglogical OWNER TO root;
GRANT USAGE ON SCHEMA pglogical TO root;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO root;

-- Grant DMS read on every user schema in this DB (idempotent).
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

-- Report installed extension + CDC-blocking tables (no PK) for this DB.
SELECT current_database() AS db, extname, extversion
FROM pg_extension
WHERE extname = 'pglogical';

SELECT current_database() AS db,
       n.nspname          AS schema,
       c.relname          AS table_no_pk,
       c.relreplident     AS replica_identity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pglogical')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  )
ORDER BY 2,3;
