-- ============================================================
-- MySQL Instance Health Check Queries
-- ============================================================
--
-- PURPOSE
--   Read-only diagnostic sweep for a single MySQL instance. Run ad hoc during
--   incident triage, or on a schedule to snapshot instance health over time.
--   Every statement is SELECT/SHOW only — nothing here writes data or changes
--   configuration, so it is safe to run against production without a change window.
--
-- HOW TO RUN
--   - mysql CLI: `mysql -h <host> -u <user> -p < mysql_health_check.sql` or run
--     interactively with `\G` after queries you want in vertical format.
--   - GUI clients (DataGrip, Workbench, DBeaver): open the file and execute
--     statement-by-statement (each numbered section is independent); running the
--     whole script at once only shows the last result set in most GUI clients.
--   - Sections are numbered and can be run individually and out of order.
--
-- REQUIRED PRIVILEGES
--   - PROCESS            (information_schema.processlist, innodb_trx/data_lock_waits)
--   - REPLICATION CLIENT  (SHOW REPLICA STATUS)
--   - SELECT on performance_schema, information_schema (granted by default to most roles)
--   - No SUPER/write privileges are needed anywhere in this script.
--
-- VERSION COMPATIBILITY
--   - Written for MySQL 8.0 and 8.4. Section 3 auto-detects the major.minor
--     version at runtime (via a dynamically prepared statement) because
--     `Innodb_history_list_length` moved from global_status (8.0) to
--     information_schema.innodb_metrics (8.4).
--   - Not tested against MySQL 5.7 or MariaDB; performance_schema table/column
--     names differ enough that several sections would need rewriting.
--
-- OUTPUT INTERPRETATION
--   Each section's comment block states the healthy/warning/critical threshold
--   for its key metric where one is well established. Thresholds are general
--   guidance, not hard alarms — validate against this instance's normal baseline
--   (e.g., via prior snapshots) before treating a single reading as an incident.
--
-- TABLE OF CONTENTS
--    1. Uptime & version               - instance identity, confirm you're on the right box
--    2. Connections                    - connection saturation, auth failures
--    3. InnoDB row ops & history list   - read/write mix, undo purge lag (version-aware)
--    4. Slow queries & table locks     - query performance, lock contention
--    5. Temp tables (disk vs memory)   - queries spilling sorts/groups to disk
--    6. Replication status             - replica lag/health (empty = not a replica)
--    7. Active long-running queries    - queries running > 5s right now
--    8. InnoDB deadlocks & lock waits  - cumulative counters, recent errors, recent statements
--    9. Current InnoDB lock waits      - live blocker/waiter pairs
--   10. Table cache efficiency         - table_open_cache sizing
--   11. Largest tables by size         - disk consumers, OPTIMIZE TABLE candidates
--   12. Disk I/O (file-level)          - InnoDB file latency, storage bottlenecks
--   13. Key global variables check     - config snapshot (buffer pool, durability, replication)
--   14. Memory                        - buffer pool hit ratio, session buffer sizing, pressure signals
--   15. Binary log disk usage          - binlog retention/size
--
-- 1. UPTIME & VERSION
-- Basic instance identity and availability check.
SELECT VERSION() AS version,            -- MySQL version string (e.g., 8.0.36 or 8.4.0); confirms patch level
       @@hostname AS hostname,           -- Server hostname; useful to confirm which instance you're connected to
       @@port AS port,                   -- Listening port
       VARIABLE_VALUE AS uptime_seconds, -- Seconds since last restart; low value = recent crash or maintenance
       ROUND(VARIABLE_VALUE/86400, 1) AS uptime_days  -- Same as above in days for quick readability
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Uptime';

-- 2. CONNECTIONS
-- Checks connection saturation and failed connection attempts.
SELECT
  gs1.VARIABLE_VALUE AS current_connections,   -- Active client connections right now
  gv.VARIABLE_VALUE AS max_connections,        -- Configured ceiling; hitting this causes "Too many connections" errors
  gs2.VARIABLE_VALUE AS max_used_connections,  -- High-water mark since startup; shows peak demand
  ROUND(gs1.VARIABLE_VALUE / gv.VARIABLE_VALUE * 100, 1) AS pct_used,  -- Current usage as % of max; > 80% = risk of exhaustion
  gs3.VARIABLE_VALUE AS aborted_connects,      -- Failed connection attempts (auth failures, timeout, etc.); growing = investigate
  gs4.VARIABLE_VALUE AS threads_running        -- Threads actively executing queries (not sleeping); spikes = contention
FROM performance_schema.global_status gs1
JOIN performance_schema.global_variables gv ON gv.VARIABLE_NAME = 'max_connections'
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Max_used_connections'
JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = 'Aborted_connects'
JOIN performance_schema.global_status gs4 ON gs4.VARIABLE_NAME = 'Threads_running'
WHERE gs1.VARIABLE_NAME = 'Threads_connected';

-- 3. INNODB ROW OPERATIONS & HISTORY LIST
-- Shows workload profile (read vs write mix) and purge health.
-- MySQL 8.0: Innodb_history_list_length in global_status
-- MySQL 8.4: removed; must use information_schema.innodb_metrics
SET @ver = SUBSTRING_INDEX(VERSION(), '.', 2) + 0;  -- Extract major.minor version as a number (e.g., 8.0 or 8.4)

SET @sql = IF(@ver < 8.4,
  -- MySQL 8.0 path: all metrics available in performance_schema.global_status
  'SELECT
     gs1.VARIABLE_VALUE AS rows_read,              /* Total rows read by SELECT operations (cumulative since startup) */
     gs2.VARIABLE_VALUE AS rows_inserted,          /* Total rows inserted (cumulative since startup) */
     gs3.VARIABLE_VALUE AS rows_updated,           /* Total rows updated (cumulative since startup) */
     gs4.VARIABLE_VALUE AS rows_deleted,           /* Total rows deleted (cumulative since startup) */
     gs5.VARIABLE_VALUE AS history_list_length     /* Undo entries awaiting purge; healthy < 1000, critical > 100000 */
   FROM performance_schema.global_status gs1
   JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = ''Innodb_rows_inserted''
   JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = ''Innodb_rows_updated''
   JOIN performance_schema.global_status gs4 ON gs4.VARIABLE_NAME = ''Innodb_rows_deleted''
   JOIN performance_schema.global_status gs5 ON gs5.VARIABLE_NAME = ''Innodb_history_list_length''
   WHERE gs1.VARIABLE_NAME = ''Innodb_rows_read''',
  -- MySQL 8.4 path: history_list_length moved to innodb_metrics (metric: trx_rseg_history_len)
  'SELECT
     gs1.VARIABLE_VALUE AS rows_read,              /* Total rows read by SELECT operations (cumulative since startup) */
     gs2.VARIABLE_VALUE AS rows_inserted,          /* Total rows inserted (cumulative since startup) */
     gs3.VARIABLE_VALUE AS rows_updated,           /* Total rows updated (cumulative since startup) */
     gs4.VARIABLE_VALUE AS rows_deleted,           /* Total rows deleted (cumulative since startup) */
     m.COUNT AS history_list_length                /* Undo entries awaiting purge; healthy < 1000, critical > 100000 */
   FROM performance_schema.global_status gs1
   JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = ''Innodb_rows_inserted''
   JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = ''Innodb_rows_updated''
   JOIN performance_schema.global_status gs4 ON gs4.VARIABLE_NAME = ''Innodb_rows_deleted''
   CROSS JOIN information_schema.innodb_metrics m ON m.NAME = ''trx_rseg_history_len''
   WHERE gs1.VARIABLE_NAME = ''Innodb_rows_read'''
);

PREPARE stmt FROM @sql;  -- Compile the version-appropriate query
EXECUTE stmt;            -- Run it
DEALLOCATE PREPARE stmt; -- Clean up

-- 4. SLOW QUERIES & TABLE LOCKS
-- Measures query performance and table-level lock contention.
SELECT
  gs1.VARIABLE_VALUE AS slow_queries,          -- Queries exceeding long_query_time threshold (cumulative)
  gs2.VARIABLE_VALUE AS questions,             -- Total statements executed (cumulative); denominator for pct_slow
  ROUND(gs1.VARIABLE_VALUE / NULLIF(gs2.VARIABLE_VALUE, 0) * 100, 4) AS pct_slow,  -- % of all queries that are slow; > 0.1% warrants investigation
  gs3.VARIABLE_VALUE AS table_locks_waited,    -- Times a table lock request had to wait (cumulative)
  gs4.VARIABLE_VALUE AS table_locks_immediate, -- Times a table lock was granted immediately (cumulative)
  ROUND(gs3.VARIABLE_VALUE / NULLIF(gs3.VARIABLE_VALUE + gs4.VARIABLE_VALUE, 0) * 100, 2) AS pct_lock_contention  -- % of lock requests that had to wait; > 1% = contention problem
FROM performance_schema.global_status gs1
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Questions'
JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = 'Table_locks_waited'
JOIN performance_schema.global_status gs4 ON gs4.VARIABLE_NAME = 'Table_locks_immediate'
WHERE gs1.VARIABLE_NAME = 'Slow_queries';

-- 5. TEMP TABLES (disk vs memory)
-- High disk temp table ratio = queries with large sorts/groups spilling to disk (slow).
SELECT
  gs1.VARIABLE_VALUE AS tmp_tables_created,        -- Total internal temp tables created (memory + disk, cumulative)
  gs2.VARIABLE_VALUE AS tmp_disk_tables_created,   -- Temp tables that exceeded tmp_table_size/max_heap_table_size and went to disk
  ROUND(gs2.VARIABLE_VALUE / NULLIF(gs1.VARIABLE_VALUE, 0) * 100, 2) AS pct_tmp_to_disk  -- % spilling to disk; > 25% = tune tmp_table_size or optimize queries
FROM performance_schema.global_status gs1
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Created_tmp_disk_tables'
WHERE gs1.VARIABLE_NAME = 'Created_tmp_tables';

-- 6. REPLICATION STATUS (run on replica)
-- Key columns to check:
--   Replica_IO_Running: must be 'Yes' (fetching binlogs from source)
--   Replica_SQL_Running: must be 'Yes' (applying relay logs)
--   Seconds_Behind_Source: replication lag in seconds; 0 = caught up, NULL = broken
--   Last_Error: non-empty = replication is broken and needs intervention
-- Empty result (no rows) = this instance is NOT a replica; it's a standalone primary/source.
-- That is normal when connected to the writer instance.
-- Note: \G is mysql CLI only (vertical output). In DataGrip/Workbench, use semicolon instead.
SHOW REPLICA STATUS;

-- 7. ACTIVE LONG-RUNNING QUERIES (>5 seconds)
-- Identifies queries that may be causing locks, CPU pressure, or blocking other sessions.
SELECT
  id,                          -- Connection/thread ID; use KILL <id> to terminate if needed
  user,                        -- MySQL user running the query
  host,                        -- Client host:port originating the connection
  db,                          -- Current database context
  command,                     -- Thread command type (Query, Execute, etc.)
  time AS seconds,             -- Seconds the current command has been running
  state,                       -- Internal execution state (Sending data, Sorting result, etc.)
  LEFT(info, 200) AS query_truncated  -- First 200 chars of the SQL statement
FROM information_schema.processlist
WHERE command != 'Sleep'       -- Exclude idle connections
  AND time > 5                 -- Only queries running longer than 5 seconds
  AND id != CONNECTION_ID()    -- Exclude this health check session
ORDER BY time DESC;

-- 8. INNODB DEADLOCKS & LOCK WAITS
-- Cumulative lock contention metrics; compare across snapshots to detect trends.

-- 8a. Cumulative counters (since startup)
SELECT
  gs1.VARIABLE_VALUE AS innodb_deadlocks,        -- Total deadlocks detected since startup; frequent = app/schema issue
  gs2.VARIABLE_VALUE AS innodb_row_lock_waits,   -- Times a row lock request had to wait (cumulative)
  gs3.VARIABLE_VALUE AS innodb_row_lock_time_ms, -- Total time spent waiting for row locks in milliseconds (cumulative)
  ROUND(gs3.VARIABLE_VALUE / NULLIF(gs2.VARIABLE_VALUE, 0), 1) AS avg_lock_wait_ms  -- Average wait per lock event; > 500ms = significant contention
FROM performance_schema.global_status gs1
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Innodb_row_lock_waits'
JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = 'Innodb_row_lock_time'
WHERE gs1.VARIABLE_NAME = 'Innodb_deadlocks';

-- 8b. Deadlock count & last occurrence (time-aware)
-- Use LAST_SEEN to determine if deadlocks are recent (within the last hour).
-- SUM_ERROR_RAISED is cumulative since startup or last TRUNCATE of this table.
SELECT
  SUM_ERROR_RAISED AS total_deadlocks,  -- Total ER_LOCK_DEADLOCK errors raised since startup
  FIRST_SEEN,                           -- Timestamp of first deadlock since startup
  LAST_SEEN                             -- Timestamp of most recent deadlock; if within last hour, actively happening
FROM performance_schema.events_errors_summary_global_by_error
WHERE ERROR_NUMBER = 1213;

-- 8c. Recent deadlocked statements (from statement history buffer)
-- Buffer size is limited by performance_schema_events_statements_history_long_size (default ~10000).
-- Not time-windowed — shows whatever is still in the ring buffer.
SELECT
  THREAD_ID,                                              -- Internal thread ID
  SQL_TEXT,                                               -- The statement that was deadlocked (victim)
  MYSQL_ERRNO,                                            -- 1213 = ER_LOCK_DEADLOCK
  RETURNED_SQLSTATE,                                      -- '40001' = serialization failure (deadlock)
  MESSAGE_TEXT,                                           -- Error message text
  TIMER_END - TIMER_START AS duration_pico,               -- Statement duration in picoseconds
  ROWS_AFFECTED,                                          -- Rows affected before rollback
  DATE_SUB(NOW(), INTERVAL (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Uptime') - TIMER_END/1000000000000 SECOND) AS approx_time  -- Approximate wall-clock time of the statement
FROM performance_schema.events_statements_history_long
WHERE MYSQL_ERRNO = 1213
ORDER BY TIMER_END DESC
LIMIT 20;

-- 9. CURRENT INNODB LOCK WAITS (who's blocking whom)
-- Real-time view of blocked transactions; empty result = no current lock waits.
SELECT
  r.trx_id AS waiting_trx_id,              -- Transaction ID of the session that is waiting/blocked
  r.trx_mysql_thread_id AS waiting_thread, -- Thread ID of the waiting session (use with KILL)
  r.trx_query AS waiting_query,            -- SQL statement the waiting session is trying to execute
  b.trx_id AS blocking_trx_id,            -- Transaction ID of the session holding the lock
  b.trx_mysql_thread_id AS blocking_thread,-- Thread ID of the blocker (use with KILL if needed)
  b.trx_query AS blocking_query,           -- SQL the blocker is running (NULL if idle in transaction)
  TIMEDIFF(NOW(), r.trx_started) AS wait_duration  -- How long the waiting transaction has been open
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID;

-- 10. TABLE CACHE EFFICIENCY
-- Tracks whether MySQL can keep table file descriptors open or must repeatedly open/close.
SELECT
  gs1.VARIABLE_VALUE AS open_tables,           -- Tables currently open in the cache
  @@table_open_cache AS table_open_cache,      -- Max tables allowed in cache; ceiling for open_tables
  gs2.VARIABLE_VALUE AS opened_tables,         -- Cumulative times a table had to be opened (cache miss); growing fast = cache too small
  ROUND(gs1.VARIABLE_VALUE / @@table_open_cache * 100, 1) AS pct_cache_used  -- How full the cache is; near 100% with high opened_tables = increase table_open_cache
FROM performance_schema.global_status gs1
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Opened_tables'
WHERE gs1.VARIABLE_NAME = 'Open_tables';

-- 11. LARGEST TABLES BY SIZE
-- Identifies disk space consumers and fragmentation candidates for OPTIMIZE TABLE.
SELECT
  table_schema,                                          -- Database name
  table_name,                                            -- Table name
  table_rows,                                            -- Estimated row count (InnoDB approximation)
  ROUND(data_length / 1024 / 1024, 2) AS data_mb,       -- Space used by table data in MB
  ROUND(index_length / 1024 / 1024, 2) AS index_mb,     -- Space used by indexes in MB
  ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb,  -- Combined data + index size
  ROUND((data_length + index_length) / 1024 / 1024 / 1024, 3) AS total_gb,  -- Combined data + index size in GB
  ROUND(data_free / 1024 / 1024, 2) AS fragmented_mb    -- Allocated but unused space (fragmentation); high = run OPTIMIZE TABLE
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND table_type = 'BASE TABLE'
ORDER BY (data_length + index_length) DESC
LIMIT 20;

-- 12. DISK I/O (file-level)
-- Reveals I/O latency on critical InnoDB files; high latency = storage bottleneck.
-- Thresholds (avg per op = total_latency / count):
--   Healthy: < 1 ms read, < 1 ms write
--   Warning: 1-5 ms read, 1-10 ms write
--   Critical: > 5 ms read, > 10 ms write
--   Redo logs (ib_logfile): most sensitive; > 0.5 ms avg = commit throughput impacted
-- On RDS: high latency usually = IOPS burst credit exhausted or instance bandwidth limit hit.
SELECT
  file_name,                    -- Physical file path on disk
  count_read,                   -- Total read operations against this file (cumulative)
  ROUND(sum_timer_read / 1000000000 / NULLIF(count_read, 0), 3) AS avg_read_ms,  -- Average ms per read op; healthy < 1, critical > 5
  count_write,                  -- Total write operations against this file (cumulative)
  ROUND(sum_timer_write / 1000000000 / NULLIF(count_write, 0), 3) AS avg_write_ms,  -- Average ms per write op; healthy < 1, critical > 10
  ROUND((sum_number_of_bytes_read + sum_number_of_bytes_write) / 1024 / 1024, 2) AS total_io_mb  -- Total bytes transferred in MB
FROM performance_schema.file_summary_by_instance
WHERE file_name LIKE '%ibdata%'      -- System tablespace
   OR file_name LIKE '%ib_logfile%'  -- Redo logs (critical for write performance)
   OR file_name LIKE '%ibtmp%'       -- Temp tablespace (sorts/joins spilling to disk)
ORDER BY (sum_timer_read + sum_timer_write) DESC
LIMIT 10;

-- 13. KEY GLOBAL VARIABLES CHECK
-- Snapshot of critical configuration; verify expected values after changes or failovers.
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
  'innodb_buffer_pool_size',          -- Memory for InnoDB cache (should be ~70-80% of available RAM)
  'innodb_log_file_size',             -- Redo log size; larger = better write throughput, longer crash recovery
  'innodb_flush_log_at_trx_commit',   -- 1=ACID compliant (safe), 0 or 2=faster but risk data loss on crash
  'sync_binlog',                      -- 1=sync binlog every commit (safe), 0=OS flush (faster, risky)
  'max_connections',                  -- Connection ceiling
  'long_query_time',                  -- Threshold in seconds for slow query log
  'slow_query_log',                   -- ON/OFF; must be ON to capture slow queries
  'log_bin',                          -- ON=binary logging enabled (required for replication/PITR)
  'binlog_format',                    -- ROW recommended for replication safety
  'innodb_file_per_table',            -- ON=each table gets its own .ibd file (recommended)
  'innodb_flush_method',              -- O_DIRECT recommended on Linux to avoid double-buffering
  'read_only',                        -- ON=instance is read-only (typical for replicas)
  'super_read_only',                  -- ON=even SUPER users can't write (replica protection)
  'innodb_deadlock_detect',           -- ON=active deadlock detection; OFF on high-concurrency to reduce overhead
  'innodb_lock_wait_timeout'          -- Seconds a transaction waits for a lock before erroring out (default 50)
)
ORDER BY VARIABLE_NAME;

-- 14. MEMORY
-- Buffer pool efficiency, memory configuration, and pressure indicators.

-- 14a. InnoDB Buffer Pool
-- Cache hit ratio and dirty page pressure; low hit ratio = buffer pool too small for working set.
SELECT
  ROUND(@@innodb_buffer_pool_size / 1024 / 1024 / 1024, 2) AS buffer_pool_gb,  -- Total memory allocated to the InnoDB buffer pool (in GB)
  gs1.VARIABLE_VALUE AS bp_read_requests,       -- Total logical read requests served from the buffer pool (cumulative since startup)
  gs2.VARIABLE_VALUE AS bp_reads_from_disk,     -- Reads that could NOT be satisfied from the buffer pool and required disk I/O
  ROUND((1 - gs2.VARIABLE_VALUE / NULLIF(gs1.VARIABLE_VALUE, 0)) * 100, 2) AS bp_hit_ratio_pct,  -- Cache hit ratio; target >= 99%. Lower means too many disk reads (buffer pool too small or working set too large)
  gs3.VARIABLE_VALUE AS bp_pages_dirty,         -- Pages in the buffer pool that have been modified but not yet flushed to disk
  gs4.VARIABLE_VALUE AS bp_pages_total,         -- Total number of pages allocated in the buffer pool
  ROUND(gs3.VARIABLE_VALUE / NULLIF(gs4.VARIABLE_VALUE, 0) * 100, 2) AS pct_dirty  -- Percentage of buffer pool pages that are dirty; sustained high values may indicate I/O bottleneck or aggressive write load
FROM performance_schema.global_status gs1
JOIN performance_schema.global_status gs2 ON gs2.VARIABLE_NAME = 'Innodb_buffer_pool_reads'
JOIN performance_schema.global_status gs3 ON gs3.VARIABLE_NAME = 'Innodb_buffer_pool_pages_dirty'
JOIN performance_schema.global_status gs4 ON gs4.VARIABLE_NAME = 'Innodb_buffer_pool_pages_total'
WHERE gs1.VARIABLE_NAME = 'Innodb_buffer_pool_read_requests';

-- 14b. Memory & Temp Table Configuration
-- Per-session and global memory allocation settings that affect temp table spills and sort performance.
-- VARIABLE_VALUE is in bytes; value_mb converts to MB for readability.
-- Non-memory variables (counts, percentages) show 0.00 in value_mb — ignore for those rows.
SELECT
  VARIABLE_NAME,
  VARIABLE_VALUE,
  ROUND(VARIABLE_VALUE / 1024 / 1024, 2) AS value_mb  -- Human-readable MB conversion (only meaningful for byte-valued settings)
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
  'tmp_table_size',                   -- Max size for in-memory internal temp tables (per query); exceeded = spills to disk
  'max_heap_table_size',              -- Max size for MEMORY engine tables; also caps internal temp tables (whichever is lower wins)
  'sort_buffer_size',                 -- Per-session buffer for sorts; larger = fewer disk sorts but more RAM per connection
  'join_buffer_size',                 -- Per-session buffer for joins without indexes; larger helps full-table-join performance
  'read_buffer_size',                 -- Per-session buffer for sequential table scans
  'read_rnd_buffer_size',             -- Per-session buffer for sorted-row reads (after ORDER BY)
  'bulk_insert_buffer_size',          -- Buffer for bulk INSERT/LOAD DATA operations (per session)
  'innodb_sort_buffer_size',          -- Buffer for InnoDB sorts during index creation (ALTER TABLE, CREATE INDEX)
  'innodb_buffer_pool_instances',     -- Number of buffer pool instances; reduces mutex contention (>= 8 for large pools)
  'innodb_log_buffer_size',           -- Buffer for redo log writes before flushing to disk; larger = fewer flushes for big txns
  'innodb_change_buffer_max_size',    -- % of buffer pool for change buffering (secondary index updates); 0 = disabled
  'key_buffer_size',                  -- MyISAM key cache (usually low priority for InnoDB-only workloads)
  'thread_cache_size',                -- Cached threads for reuse; reduces thread creation overhead on connect storms
  'table_open_cache',                 -- Max file descriptors for open tables
  'binlog_cache_size',                -- Per-session cache for binlog events in a transaction before flush
  'net_buffer_length'                 -- Starting size of per-connection network buffer (grows to max_allowed_packet)
)
ORDER BY VARIABLE_NAME;

-- 14c. Memory Pressure Indicators
-- Direct signals that the instance is running low on memory or buffer pool headroom.
-- bp_wait_free > 0 is the single strongest indicator of memory pressure (InnoDB stalled waiting for a free page).
-- pct_bp_free < 5% means the buffer pool is nearly full and approaching eviction pressure.
-- read_ahead_evicted growing = prefetched pages evicted before use (working set exceeds pool).
-- worst_case_session_mem_mb = theoretical max if every connection simultaneously uses all per-session buffers.
-- On RDS, also monitor CloudWatch FreeableMemory (not visible from SQL).
SELECT
  bp_free.VARIABLE_VALUE AS bp_pages_free,          -- Free pages available in the buffer pool right now
  bp_total.VARIABLE_VALUE AS bp_pages_total,        -- Total pages allocated in the buffer pool
  ROUND(bp_free.VARIABLE_VALUE / bp_total.VARIABLE_VALUE * 100, 1) AS pct_bp_free,  -- % free; < 5% = pressure imminent
  wait_free.VARIABLE_VALUE AS bp_wait_free,         -- > 0 = definitive memory pressure (had to evict synchronously to serve a read)
  ra_evict.VARIABLE_VALUE AS read_ahead_evicted,    -- Read-ahead pages evicted before being accessed (wasted prefetch = pool too small)
  ROUND(@@innodb_buffer_pool_size / 1024 / 1024 / 1024, 2) AS bp_configured_gb,  -- Buffer pool size in GB for reference
  (SELECT COUNT(*) FROM information_schema.processlist) AS current_connections,    -- Active connections contributing to session memory
  ROUND((SELECT COUNT(*) FROM information_schema.processlist)
    * (@@sort_buffer_size + @@join_buffer_size + @@read_buffer_size + @@read_rnd_buffer_size + @@binlog_cache_size)
    / 1024 / 1024, 1) AS worst_case_session_mem_mb  -- Theoretical max per-session memory if all connections sort+join simultaneously
FROM performance_schema.global_status bp_free
JOIN performance_schema.global_status bp_total ON bp_total.VARIABLE_NAME = 'Innodb_buffer_pool_pages_total'
JOIN performance_schema.global_status wait_free ON wait_free.VARIABLE_NAME = 'Innodb_buffer_pool_wait_free'
JOIN performance_schema.global_status ra_evict ON ra_evict.VARIABLE_NAME = 'Innodb_buffer_pool_read_ahead_evicted'
WHERE bp_free.VARIABLE_NAME = 'Innodb_buffer_pool_pages_free';

-- 14d. InnoDB Buffer Pool Utilization Snapshot (quick operator view)
-- Purpose:
--   Provide a compact, human-readable snapshot of InnoDB buffer pool occupancy
--   and write pressure to support fast triage during incidents and daily checks.
--
-- How to read:
--   data_pct  = share of buffer pool currently holding data pages.
--   dirty_pct = share of dirty pages waiting to be flushed; sustained elevation can
--               indicate flush lag or checkpoint pressure on write-heavy workloads.
--   free_pct  = immediate eviction headroom; persistently low values imply churn and
--               higher risk of synchronous evictions under read pressure.
--
-- Status thresholds (free_pct):
--   < 0.5%  -> CRITICAL: near-zero headroom; expect elevated latency risk.
--   < 2.0%  -> LOW: constrained headroom; monitor closely for spikes.
--   < 5.0%  -> OK: workable but limited margin.
--   >= 5.0% -> HEALTHY: comfortable operating headroom.
SELECT
  FORMAT(pages_total, 0)                          AS pages_total,  -- Total allocated buffer pool pages
  FORMAT(pages_data,  0)                          AS pages_data,   -- Pages currently used for data/index contents
  FORMAT(pages_dirty, 0)                          AS pages_dirty,  -- Modified pages pending flush to disk
  FORMAT(pages_free,  0)                          AS pages_free,   -- Free pages immediately available
  ROUND(pages_data  * 100.0 / pages_total, 2)     AS `data_pct (utilization)`,
  ROUND(pages_dirty * 100.0 / pages_total, 2)     AS `dirty_pct (write pressure / flush lag)`,
  ROUND(pages_free  * 100.0 / pages_total, 3)     AS `free_pct (eviction headroom)`,
  CASE
    WHEN pages_free * 100.0 / pages_total < 0.5 THEN '🔴 CRITICAL'
    WHEN pages_free * 100.0 / pages_total < 2.0 THEN '🟡 LOW'
    WHEN pages_free * 100.0 / pages_total < 5.0 THEN '🟢 OK'
    ELSE                                             '🟢 HEALTHY'
  END                                              AS status
FROM (
  SELECT
    MAX(CASE WHEN VARIABLE_NAME='Innodb_buffer_pool_pages_total' THEN VARIABLE_VALUE END) +0 AS pages_total,
    MAX(CASE WHEN VARIABLE_NAME='Innodb_buffer_pool_pages_data'  THEN VARIABLE_VALUE END) +0 AS pages_data,
    MAX(CASE WHEN VARIABLE_NAME='Innodb_buffer_pool_pages_dirty' THEN VARIABLE_VALUE END) +0 AS pages_dirty,
    MAX(CASE WHEN VARIABLE_NAME='Innodb_buffer_pool_pages_free'  THEN VARIABLE_VALUE END) +0 AS pages_free
  FROM performance_schema.global_status
  WHERE VARIABLE_NAME IN (
    'Innodb_buffer_pool_pages_total',
    'Innodb_buffer_pool_pages_data',
    'Innodb_buffer_pool_pages_dirty',
    'Innodb_buffer_pool_pages_free'
  )
) bp;


-- 15. BINARY LOG DISK USAGE
-- Shows all binary log files and their sizes.
-- Watch for: total size consuming significant disk, too many files retained.
-- Controlled by: binlog_expire_logs_seconds (8.0+) or expire_logs_days (deprecated).
SHOW BINARY LOGS;


