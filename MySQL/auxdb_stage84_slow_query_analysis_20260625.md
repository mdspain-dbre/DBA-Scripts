# Slow Query Log Analysis — AuxDB Stage 8.4

**Instance**: `prod-rds-auxdb-stage-84-20260602` (MySQL 8.4.5, db.r6i.xlarge)  
**Analysis Period**: 2026-06-25 07:25 → 17:29 UTC  
**Database**: `ingest`

---

## Executive Summary

| Metric                | Value              |
|-----------------------|--------------------|
| Total slow queries    | 562                |
| Total slow query time | 2,424s (40.4 min)  |
| Average query time    | 4.31s              |
| Queries > 10s         | 40                 |
| Queries > 60s         | 5                  |
| Queries > 100s        | 2                  |

Peak activity at **07:00–08:00 UTC** (121 queries, 1,178s total) driven by maintenance jobs (persistence builds, `count(*)` checks, and the `master_content_index_to_delete` population).

---

## Top Offenders by Total Time

| #  | Pattern                                                          | Count | Total(s) | Avg(s) | Max(s) | Avg Rows Examined |
|----|------------------------------------------------------------------|-------|----------|--------|--------|-------------------|
| 1  | `UPDATE master_autocommercial_index ... SET last_seen = NOW()`   | 25    | 342      | 13.7   | 18.2   | 143               |
| 2  | `SELECT tms_schedule` (airtime variant)                          | 132   | 278      | 2.1    | 10.7   | 2,180,070         |
| 3  | `SELECT tms_schedule` (title/XML variant)                        | 132   | 261      | 2.0    | 4.4    | 2,172,447         |
| 4  | `SELECT count(1) FROM schedule_restore`                          | 1     | 257      | 257    | 257    | 0                 |
| 5  | `call build_live_persistence_audio(...)`                         | 54    | 182      | 3.4    | 3.6    | 43,092,854        |
| 6  | `REPLACE INTO schedule (...)`                                    | 1     | 161      | 161    | 161    | 1,651,722         |
| 7  | `DELETE FROM master_content_index WHERE mci_idx IN (...)`        | 37    | 141      | 3.8    | 4.7    | 6,270,164         |
| 8  | `SELECT count(1) FROM schedule`                                  | 1     | 91       | 91     | 91     | 0                 |
| 9  | `DELETE FROM schedule WHERE tf_air_date < ...`                   | 1     | 89       | 89     | 89     | 68,732,453        |
| 10 | `REPLACE INTO program (...)`                                     | 1     | 86       | 86     | 86     | 302,208           |
| 11 | `call build_file_persistence(...)`                               | 54    | 71       | 1.3    | 1.7    | 1,401,574         |

---

## Detailed Findings

### 1. 🔴 `UPDATE master_autocommercial_index` — 342s total (worst offender)

```sql
UPDATE master_autocommercial_index mai
INNER JOIN autocommercial_hit_updates ahc ON mai.mci_idx = ahc.mci_idx
SET mai.last_seen = NOW();
```

- **25 executions** from 25 different hosts (appears to be a distributed worker pattern — each worker fires independently)
- Averages **13.7s** but only updates **143–196 rows**
- **Problem**: The JOIN is likely scanning `master_autocommercial_index` fully because `autocommercial_hit_updates` lacks an index on `mci_idx`, or the table has heavy row locking contention with 25 concurrent UPDATEs.
- **Recommendation**:
  - Verify index exists on `autocommercial_hit_updates(mci_idx)`
  - Consider serializing or batching — 25 concurrent UPDATEs on the same table causes row-lock contention
  - Run `EXPLAIN` on the SELECT equivalent to check execution plan

---

### 2. 🔴 `tms_schedule` SELECT queries — 539s total (highest frequency)

**Variant A** (132 occurrences, avg 2.1s):
```sql
SELECT tms_schedule.tf_database_key, tms_schedule.tf_station_num, ...
FROM tms_schedule, signals, program, station LEFT JOIN dma ...
WHERE site_id=1
  AND tms_schedule.tf_station_num = signals.station_id
  AND tms_schedule.tf_air_date >= '20260617'
  AND tms_schedule.tf_air_date <= '20260628'
  AND program.tf_database_key = tms_schedule.tf_database_key;
```

- ~2.2M rows examined per execution for an 11-day date range
- **Problem**: Implicit comma-style JOINs with no covering index on `(tf_air_date, tf_station_num, tf_database_key)` — likely doing full scans on `tms_schedule`
- **Recommendation**:
  - Add composite index: `CREATE INDEX idx_schedule_date_station ON tms_schedule(tf_air_date, tf_station_num, tf_database_key)`
  - Convert from comma-join syntax to explicit `JOIN ... ON` for optimizer hints
  - Source: 3 hosts (`172.17.46.194`, `172.17.142.225`, `10.145.76.26`) — likely app servers polling on a schedule

---

### 3. 🟠 `SELECT count(1) FROM <table>` — 562s total across many tables

These are full **InnoDB table scans** (rows_examined = 0 in slow log means InnoDB count traversal):

| Table                                            | Time(s) |
|--------------------------------------------------|---------|
| `schedule_restore`                               | 257     |
| `schedule`                                       | 91      |
| `master_live_index_backup_20240117`              | 45      |
| `master_autocommercial_index_backup_20240117`    | 30      |
| `tms_program_0102`                               | 20      |
| `master_live_index_amoore_baseline`              | 20      |
| Various other backups                            | 10–19   |

- **Problem**: InnoDB `count(*)` requires a full index scan. Many of these are **backup/archive tables** (`_backup_20240117`, `_amoore_baseline`, `_separation_backup`) that likely shouldn't be queried regularly.
- **Source**: `10.145.76.26` — appears to be a monitoring or inventory script running `select count(1)` against every table
- **Recommendation**:
  - Identify the monitoring script and exclude backup tables, or use `information_schema.TABLES` for approximate counts
  - Consider dropping or archiving old backup tables (`_backup_20240117` is 18 months old)

---

### 4. 🟠 `build_live_persistence_audio()` — 182s total

```sql
call build_live_persistence_audio(118, @success);
-- Called with args: -1, 118, 1, 3, 7, 13, 113
```

- 54 executions × 3.4s avg, scanning **43M rows** per call
- Runs every scheduled interval from `172.17.129.158`
- **Problem**: Stored procedure likely does full scans on `master_live_index` or similar large tables
- **Recommendation**: Inspect stored procedure body — likely needs index optimization inside the proc

---

### 5. 🟠 `DELETE FROM schedule WHERE tf_air_date < ...` — 89s

```sql
DELETE FROM schedule
WHERE tf_air_date < REPLACE(DATE_SUB(DATE(NOW()), INTERVAL 730 DAY), '-', '');
```

- Single execution, **68.7M rows examined**, deletes old records (>2 years)
- **Problem**: If `tf_air_date` is stored as a string (`YYYYMMDD`), the `REPLACE()` call on the constant is fine, but the table may lack an index on `tf_air_date`, or the delete is too large for one transaction.
- **Recommendation**:
  - Verify index on `schedule(tf_air_date)`
  - Batch deletes: `DELETE ... LIMIT 10000` in a loop to avoid long-running transactions and replication lag

---

### 6. 🟡 `INSERT INTO master_content_index_to_delete` — 28s

```sql
INSERT INTO master_content_index_to_delete (mci_idx, state, last_updated)
SELECT mci_idx, state, last_updated
FROM master_content_index
LEFT OUTER JOIN master_file_index USING (mci_idx)
LEFT OUTER JOIN master_autocommercial_index USING (mci_idx)
LEFT OUTER JOIN master_live_index USING (mci_idx)
WHERE master_file_index.mci_idx IS NULL
  AND master_autocommercial_index.mci_idx IS NULL
  AND master_live_index.mci_idx IS NULL;
```

- 12.5M rows examined — anti-join pattern (find orphans)
- **Recommendation**: Verify indexes on `mci_idx` in all 3 joined tables. Consider running during off-peak.

---

## Hourly Distribution

| Hour (UTC) | Count | Total Time(s) | Notes                                    |
|------------|-------|---------------|------------------------------------------|
| 07:00      | 121   | 1,178         | Maintenance jobs + count scans           |
| 11:00      | 148   | 631           | TMS schedule loads + schedule DELETE     |
| 12:00      | 222   | 460           | TMS schedule queries (highest frequency) |
| 13:00      | 55    | 119           | Tail end of TMS activity                 |
| 17:00      | 16    | 36            | Persistence builds                       |

---

## Relevance to Config Differences (Stage vs Prod)

The `tmp_table_size` / `max_heap_table_size` difference (200 MB stage vs 1.9 GB prod) is **directly relevant** to the `tms_schedule` queries:
- These queries scan 2.2M rows with GROUP BY / JOIN patterns
- On stage, internal temp tables hit the 200 MB cap and spill to disk sooner
- This partially explains why these queries may run slower on stage than prod

The `innodb_buffer_pool_instances = 1` is relevant to the `UPDATE master_autocommercial_index` contention — with 25 concurrent writers updating the same table, a single buffer pool instance creates more mutex pressure.

---

## Priority Recommendations

| Priority | Action                                                                              | Expected Impact                                 |
|----------|-------------------------------------------------------------------------------------|-------------------------------------------------|
| **P1**   | Index `autocommercial_hit_updates(mci_idx)` — verify exists                         | Fixes 342s/day of UPDATE contention             |
| **P1**   | Add composite index on `tms_schedule(tf_air_date, tf_station_num, tf_database_key)` | Fixes 539s/day (264 queries)                    |
| **P2**   | Raise `tmp_table_size` / `max_heap_table_size` to match prod (2 GB)                 | Reduces disk spills for tms_schedule queries    |
| **P2**   | Set `innodb_buffer_pool_instances = 8` to match prod                                | Reduces mutex contention for concurrent writes  |
| **P2**   | Remove or stop monitoring backup tables (`*_backup_20240117`, `*_amoore*`, etc.)    | Eliminates 300s+ of useless count scans         |
| **P3**   | Batch the `DELETE FROM schedule` into chunks of 10K rows                            | Prevents 89s single-transaction deletes         |
| **P3**   | Review `build_live_persistence_audio` stored procedure internals                    | 43M row scans × 54/day                          |
