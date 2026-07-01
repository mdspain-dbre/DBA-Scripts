-- =============================================================================
-- pg_healthcheck.sql  —  Read-only PostgreSQL health check
-- =============================================================================
-- Purpose : Quickly assess whether a PostgreSQL instance (incl. CloudSQL for
--           PostgreSQL) is healthy. SELECT / SHOW only — no DDL or DML.
--
-- Usage   : psql "host=<host> user=<user> dbname=postgres sslmode=require" \
--                -P pager=off -f pg_healthcheck.sql
--           For CloudSQL IAM auth, pass the access token as the password:
--           PGPASSWORD=$(gcloud auth print-access-token) psql ... -f pg_healthcheck.sql
--
-- Notes   : Connect to a database you can read (e.g. "postgres"). A few queries
--           read cluster-wide catalogs (pg_stat_database, pg_database) and so
--           report every database regardless of the one you connect to.
--           Some columns require the pg_monitor role (or rds_superuser /
--           cloudsqlsuperuser) to see other sessions' query text.
-- =============================================================================

\pset pager off
\timing off

-- -----------------------------------------------------------------------------
-- 1. VERSION, UPTIME, ROLE (primary vs replica)
--    is_replica = t means this node is in recovery (a standby/read replica).
-- -----------------------------------------------------------------------------
\echo '=== 1. VERSION / UPTIME / ROLE ==='
SELECT version() AS version;
SELECT date_trunc('second', now() - pg_postmaster_start_time()) AS uptime,
       pg_is_in_recovery()                                       AS is_replica,
       current_setting('server_version')                         AS server_version;

-- -----------------------------------------------------------------------------
-- 2. CONNECTIONS vs max_connections
--    WATCH if pct_used > 80%. idle_in_txn sessions hold locks/XID — investigate
--    any that are long-lived (see section 4).
-- -----------------------------------------------------------------------------
\echo '=== 2. CONNECTIONS ==='
SELECT count(*)                                                   AS total,
       count(*) FILTER (WHERE state = 'active')                   AS active,
       count(*) FILTER (WHERE state = 'idle in transaction')      AS idle_in_txn,
       count(*) FILTER (WHERE wait_event_type = 'Lock')           AS waiting_on_lock,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_conn,
       round(100.0 * count(*)
             / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 1) AS pct_used
FROM pg_stat_activity;

-- Connections grouped by database / user / state (top 15)
\echo '--- connections by db / user / state ---'
SELECT datname, usename, state, count(*) AS conns
FROM pg_stat_activity
WHERE datname IS NOT NULL
GROUP BY datname, usename, state
ORDER BY conns DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 3. LONGEST-RUNNING ACTIVE QUERIES (> 5s)
--    Long-running queries can block autovacuum and pin old row versions.
-- -----------------------------------------------------------------------------
\echo '=== 3. LONG-RUNNING ACTIVE QUERIES (>5s) ==='
SELECT pid,
       usename,
       datname,
       state,
       date_trunc('second', now() - query_start) AS duration,
       wait_event_type,
       wait_event,
       left(query, 100)                           AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND query_start IS NOT NULL
  AND now() - query_start > interval '5 seconds'
  AND pid <> pg_backend_pid()
ORDER BY now() - query_start DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- 4. IDLE-IN-TRANSACTION SESSIONS
--    These hold a transaction open (locks + old XID). Anything older than a few
--    minutes is a problem; long ones cause bloat and block vacuum.
-- -----------------------------------------------------------------------------
\echo '=== 4. IDLE IN TRANSACTION ==='
SELECT pid,
       usename,
       datname,
       date_trunc('second', now() - state_change) AS idle_duration,
       left(query, 100)                            AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY now() - state_change DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- 5. CACHE HIT RATIO / DEADLOCKS / CONFLICTS / TEMP FILES  (per database)
--    cache_hit_pct should be >= 99% for an OLTP workload.
--    deadlocks > 0 or rising temp_files warrant a closer look.
-- -----------------------------------------------------------------------------
\echo '=== 5. CACHE HIT / DEADLOCKS / CONFLICTS / TEMP (per db) ==='
SELECT datname,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       deadlocks,
       conflicts,
       temp_files,
       pg_size_pretty(temp_bytes)                                   AS temp_bytes,
       xact_commit,
       xact_rollback,
       round(100.0 * xact_rollback / nullif(xact_commit + xact_rollback, 0), 2) AS pct_rollback
FROM pg_stat_database
WHERE datname IS NOT NULL
  AND datname NOT IN ('template0', 'template1')
ORDER BY (blks_hit + blks_read) DESC;

-- -----------------------------------------------------------------------------
-- 6. DATABASE SIZES
-- -----------------------------------------------------------------------------
\echo '=== 6. DATABASE SIZES ==='
SELECT datname,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY pg_database_size(datname) DESC;

-- -----------------------------------------------------------------------------
-- 7. REPLICATION — DOWNSTREAM (run on a primary)
--    Shows connected standbys and their lag. Empty on a standalone primary.
-- -----------------------------------------------------------------------------
\echo '=== 7. REPLICATION — DOWNSTREAM STANDBYS ==='
SELECT client_addr,
       application_name,
       state,
       sync_state,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;

-- -----------------------------------------------------------------------------
-- 8. REPLICATION — THIS NODE'S LAG (run on a replica)
--    replica_lag_seconds = how far behind the primary this standby is.
--    Returns NULL on a primary (not in recovery).
-- -----------------------------------------------------------------------------
\echo '=== 8. REPLICATION — LOCAL LAG (if replica) ==='
SELECT pg_is_in_recovery() AS is_replica,
       CASE WHEN pg_is_in_recovery()
            THEN date_trunc('second', now() - pg_last_xact_replay_timestamp())
            ELSE NULL END AS replica_lag,
       pg_last_xact_replay_timestamp() AS last_replay_ts;

-- -----------------------------------------------------------------------------
-- 9. TRANSACTION-ID WRAPAROUND RISK
--    pct_toward_wraparound approaching 100% is an emergency (forced shutdown at
--    ~2.1B). Anything over ~50% means autovacuum is not keeping up.
-- -----------------------------------------------------------------------------
\echo '=== 9. XID WRAPAROUND RISK (top 10 databases) ==='
SELECT datname,
       age(datfrozenxid)                              AS xid_age,
       round(100.0 * age(datfrozenxid) / 2.1e9, 2)    AS pct_toward_wraparound
FROM pg_database
ORDER BY age(datfrozenxid) DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- 10. BLOCKED SESSIONS / LOCK WAITS
--     blocked_sessions > 0 means active lock contention right now.
-- -----------------------------------------------------------------------------
\echo '=== 10. BLOCKED SESSIONS ==='
SELECT count(*) AS blocked_sessions
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

\echo '--- blocking detail (blocked <- blocker) ---'
SELECT blocked.pid                          AS blocked_pid,
       blocked.usename                      AS blocked_user,
       left(blocked.query, 60)              AS blocked_query,
       blocker_pid,
       blocker.usename                      AS blocker_user,
       left(blocker.query, 60)              AS blocker_query
FROM pg_stat_activity blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocker_pid
JOIN pg_stat_activity blocker ON blocker.pid = blocker_pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 11. TABLE BLOAT / DEAD TUPLES & AUTOVACUUM (current database only)
--     High dead_pct with an old last_autovacuum indicates vacuum is behind.
--     Connect to each application database to assess its tables.
-- -----------------------------------------------------------------------------
\echo '=== 11. TOP DEAD-TUPLE TABLES (current db) ==='
SELECT schemaname,
       relname,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 12. UNUSED / RARELY-USED INDEXES (current database only)
--     idx_scan = 0 on a large index is a candidate for review (write overhead
--     with no read benefit). Excludes primary keys / unique constraints.
-- -----------------------------------------------------------------------------
\echo '=== 12. UNUSED INDEXES (current db, top 15 by size) ==='
SELECT s.schemaname,
       s.relname        AS table_name,
       s.indexrelname   AS index_name,
       s.idx_scan       AS scans,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 13. CHECKPOINTS & BGWRITER (I/O health)
--     A high ratio of requested (vs timed) checkpoints means checkpoints are
--     being forced by WAL volume — consider raising max_wal_size.
--     (pg_stat_checkpointer exists in PG17+; pg_stat_bgwriter on older versions.)
-- -----------------------------------------------------------------------------
\echo '=== 13. CHECKPOINTS / BGWRITER ==='
SELECT *
FROM pg_stat_bgwriter;

-- -----------------------------------------------------------------------------
-- 14. TOP TIME-CONSUMING STATEMENTS (requires pg_stat_statements extension)
--     Skips silently if the extension is not installed.
-- -----------------------------------------------------------------------------
\echo '=== 14. TOP STATEMENTS BY TOTAL TIME (if pg_stat_statements) ==='
SELECT round(total_exec_time::numeric, 1) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(100.0 * total_exec_time
             / nullif(sum(total_exec_time) OVER (), 0), 1) AS pct_total,
       left(query, 80)                     AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

\echo '=== HEALTH CHECK COMPLETE ==='
