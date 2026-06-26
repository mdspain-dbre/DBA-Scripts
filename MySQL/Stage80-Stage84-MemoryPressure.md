# Stage 8.0 vs Stage 8.4 — Memory Pressure Analysis (14-Day)

**Date:** 2026-06-25  
**Analyst:** DBA Team  
**Instances:**

| Property           | Stage 8.0                       | Stage 8.4                        |
|--------------------|---------------------------------|----------------------------------|
| RDS Identifier     | prod-rds-auxdb-stage80-20240820 | prod-rds-auxdb-stage-84-20260602 |
| MySQL Version      | 8.0.42                          | 8.4.5                            |
| Instance Class     | db.r6i.xlarge                   | db.r6i.xlarge                    |
| vCPUs / RAM        | 4 / ~32 GB                      | 4 / ~32 GB                       |
| Buffer Pool Size   | 22 GB                           | 22 GB                            |
| Buffer Pool Inst.  | 8                               | 1 (MySQL 8.4 dynamic default)    |
| Uptime (at sample) | 13,599,273 s (~157 days)        | 1,978,600 s (~23 days)           |

---

## Executive Summary

**Stage 8.4 shows clear memory pressure signals that Stage 8.0 does not exhibit.** The root causes are:

1. **25x higher connection count** (avg 155 vs 6) driving per-thread memory consumption
2. **Single buffer pool instance** (vs 8) creating mutex contention and less efficient page management
3. **TempTable engine RAM spikes** peaking at 7.3 GB — unique to 8.4's workload profile
4. **Hash join pointer memory** peaking at 18.1 GB — indicates massive in-memory hash operations
5. **FreeableMemory trending downward** (-260 MB over 14 days on 8.4)

**Severity: MODERATE — not yet critical but trending toward it.** No OOM events observed, but the 0.29% free buffer pool and 255 `wait_free` stalls indicate the instance is operating at its memory ceiling.

---

## 1. Buffer Pool Pressure

| Metric                         | Stage 8.0     | Stage 8.4     | Verdict                       |
|--------------------------------|---------------|---------------|-------------------------------|
| `innodb_buffer_pool_instances` | 8             | 1             | Single mutex on 8.4           |
| Pages total                    | 1,441,792     | 1,441,792     | Same                          |
| Pages data                     | 1,398,282     | 1,437,531     | 8.4 nearly full               |
| Pages free                     | 32,784 (2.3%) | 4,131 (0.29%) | 🔴 8.4 nearly saturated       |
| Pages dirty                    | 15,221        | 15,579        | Similar                       |
| Pages misc (overhead)          | 10,726        | 130           | 8.0 has per-instance overhead |
| `wait_free` (stalls)           | 0             | 255           | 🔴 8.4 stalled 255 times      |
| `read_ahead_evicted`           | 0             | 21,511        | 🔴 8.4 evicting before use    |
| Hit rate (out of 1000)         | 1000          | 1000          | Both excellent                |
| Read requests                  | 311.3 B       | 83.6 B        | 8.0 has 7x uptime             |
| Disk reads                     | 97.3 M        | 9.7 M         | Proportional to uptime        |
| Bytes data                     | 22,909 MB     | 23,552 MB     | 8.4 using 643 MB more data    |

### Key Findings

- **`wait_free = 255`** on Stage 8.4 means InnoDB had to stall 255 times waiting for a free page to become available. Stage 8.0 has zero. This is the single most significant memory pressure indicator.
- **`read_ahead_evicted = 21,511`** on 8.4 means prefetched pages were evicted from the pool before they could be used — the buffer pool is too full to benefit from read-ahead optimization.
- **Free pages at 0.29%** on 8.4 vs 2.3% on 8.0 — the 8.4 buffer pool has essentially no headroom.

---

## 2. Buffer Pool Instance Detail

### Stage 8.0 — 8 Instances

| Instance | Pages Total | Pages Free | Hit Rate | Read Ahead Evicted |
|---------:|------------:|-----------:|---------:|-------------------:|
|        0 |     180,224 |      4,097 |    1,000 |                  0 |
|        1 |     180,224 |      4,098 |    1,000 |                  0 |
|        2 |     180,224 |      4,097 |    1,000 |                  0 |
|        3 |     180,224 |      4,098 |    1,000 |                  0 |
|        4 |     180,224 |      4,098 |    1,000 |                  0 |
|        5 |     180,224 |      4,097 |    1,000 |                  0 |
|        6 |     180,224 |      4,098 |    1,000 |                  0 |
|        7 |     180,224 |      4,097 |    1,000 |                  0 |

### Stage 8.4 — 1 Instance

| Instance | Pages Total | Pages Free | Hit Rate | Read Ahead Evicted |
|---------:|------------:|-----------:|---------:|-------------------:|
|        0 |   1,441,792 |      4,131 |    1,000 |             21,511 |

**Observation:** With 8 instances on 8.0, each has ~4,097 free pages independently, distributing flush and eviction across 8 mutex regions. With 1 instance on 8.4, the same total free pages (~4,131) must serve all concurrent threads through a single mutex — creating contention under load.

---

## 3. Temp Table & Sort Pressure (Normalized by Uptime)

| Metric                    |   Stage 8.0 |  Stage 8.4 | Per-Hour 8.0 | Per-Hour 8.4 | Delta    |
|---------------------------|------------:|-----------:|-------------:|-------------:|----------|
| `Created_tmp_tables`      |  82,325,135 | 13,267,756 |       21,793 |       24,141 | +10.8%   |
| `Created_tmp_disk_tables` |  15,770,788 |  2,067,738 |        4,175 |        3,762 | -9.9%    |
| Disk-to-tmp ratio         |       19.2% |      15.6% |            — |            — | Improved |
| `Sort_merge_passes`       |      43,652 |      1,152 |         11.6 |          2.1 | -82%     |
| `Sort_rows`               | 507,078,112 | 44,659,802 |      134,199 |       81,264 | -39%     |
| `Sort_scan`               |   3,813,459 |  2,384,737 |        1,010 |        4,340 | +330%    |

### Key Findings

- 8.4 creates **10.8% more temp tables per hour** but spills fewer to disk (15.6% vs 19.2%). This suggests MySQL 8.4's TempTable engine is absorbing more work in RAM — confirmed by the 7.3 GB `temptable/physical_ram` high-water mark.
- **Sort merge passes dropped 82%** — fewer multi-pass sorts, but this may be because hash joins replaced some sort-based operations in 8.4.
- **Sort scans up 330%** per hour — 8.4 is performing significantly more full-scan sort operations, likely due to the higher connection count and workload volume.

---

## 4. Memory Allocator Analysis (performance_schema)

### Current Allocations vs High-Water Marks

| Allocator                     |   8.0 Current | 8.0 High Water |   8.4 Current | 8.4 High Water | Concern                               |
|-------------------------------|--------------:|---------------:|--------------:|---------------:|---------------------------------------|
| `buf_buf_pool`                |     23,035 MB |      23,035 MB |     23,035 MB |      23,035 MB | Same — fixed allocation               |
| `temptable/physical_ram`      |             — |              — |         62 MB |   **7,493 MB** | 🔴 Spiked to 7.3 GB                   |
| `memory/HP_PTRS`              |             — |              — |         30 MB |  **18,560 MB** | 🔴 Spiked to 18.1 GB                  |
| `innodb/log_buffer_memory`    |             — |              — |         64 MB |          64 MB | New in 8.4, stable                    |
| `sp_head::main_mem_root`      |         21 MB |       2,826 MB |         17 MB |       1,713 MB | Stored proc memory; 8.0 peaked higher |
| `innodb/memory`               |         28 MB |         355 MB |         32 MB |         264 MB | Similar                               |
| `sql/TABLE`                   |         39 MB |          85 MB |         40 MB |          40 MB | Stable                                |
| **Total allocated (current)** | **23.83 GiB** |              — | **23.74 GiB** |              — | Similar current footprint             |

### Critical Observations

1. **`temptable/physical_ram` peaked at 7,493 MB (7.3 GB):**  
   This is the MySQL TempTable storage engine holding intermediate results in RAM. With 155+ concurrent connections running queries that create temp tables, this allocator can spike enormously. Currently at 62 MB (recovered), but the peak consumed nearly 1/4 of total system RAM.

2. **`memory/HP_PTRS` peaked at 18,560 MB (18.1 GB):**  
   This tracks hash join pointer allocations in MySQL 8.4. Hash joins are the default join strategy in MySQL 8.4 (replacing nested-loop joins for many query patterns). The 18.1 GB peak indicates massive hash tables were built during join operations — likely from the `build_live_persistence_audio` stored procedures that scan 43 million rows per call.

3. **`sp_head::main_mem_root` peaked at 2,826 MB on 8.0 vs 1,713 MB on 8.4:**  
   Stored procedure memory. Despite 8.0 having fewer connections, it has 7x more uptime — the peak may reflect a historical event. On 8.4 with only 23 days of uptime, reaching 1.7 GB is proportionally concerning.

---

## 5. CloudWatch Metrics (14-Day Trend)

### FreeableMemory (MB) — Daily Average / Minimum

| Date       | Stage 8.0 Avg | Stage 8.0 Min | Stage 8.4 Avg | Stage 8.4 Min |
|------------|:-------------:|:-------------:|:-------------:|:-------------:|
| 2026-06-11 |     4,319     |     3,955     |     4,544     |     4,264     |
| 2026-06-12 |     4,296     |     4,033     |     4,519     |     4,282     |
| 2026-06-13 |     4,310     |     4,052     |     4,452     |     4,189     |
| 2026-06-14 |     4,303     |     4,047     |     4,430     |     4,204     |
| 2026-06-15 |     4,318     |     4,007     |     4,408     |     4,194     |
| 2026-06-16 |     4,258     |     4,009     |     4,390     |     4,190     |
| 2026-06-17 |     4,284     |     4,062     |     4,375     |     4,183     |
| 2026-06-18 |     4,269     |     4,061     |     4,347     |     4,184     |
| 2026-06-19 |     4,286     |     4,068     |     4,342     |     4,189     |
| 2026-06-20 |     4,264     |     4,052     |     4,337     |     4,178     |
| 2026-06-21 |     4,262     |     4,017     |     4,317     |     4,177     |
| 2026-06-22 |     4,254     |     4,049     |     4,311     |     4,171     |
| 2026-06-23 |     4,209     |     4,013     |     4,306     |     4,176     |
| 2026-06-24 |     4,204     |     4,049     |     4,284     |     4,166     |

**Stage 8.0 Trend:** Stable at ~4,200–4,320 MB. No meaningful drift.  
**Stage 8.4 Trend:** Declining from 4,544 → 4,284 MB (avg) — **loss of ~260 MB over 14 days** (~18.6 MB/day).  

At this rate, Stage 8.4 would reach Stage 8.0's current level (~4,200 MB) in approximately 5 days and could reach concerning levels (~3,500 MB) in approximately 42 days.

### SwapUsage (MB)

| Instance  | Start of Period | End of Period | Trend                   |
|-----------|:---------------:|:-------------:|-------------------------|
| Stage 8.0 |     118 MB      |    133 MB     | Slowly growing (+15 MB) |
| Stage 8.4 |      0 MB       |     0 MB      | None — no swap activity |

**Note:** Stage 8.0 using 133 MB swap despite having stable FreeableMemory suggests OS-level memory pressure from non-MySQL processes or kernel page cache competition. Stage 8.4 has zero swap, meaning all memory pressure is absorbed within the MySQL process.

### DatabaseConnections (14-Day Average)

| Instance  | Average | Maximum | Minimum |
|-----------|:-------:|:-------:|:-------:|
| Stage 8.0 |    6    |    8    |    4    |
| Stage 8.4 |   155   |   234   |   95    |

**This is the most significant difference.** Stage 8.4 has **25x more concurrent connections** than Stage 8.0. Each connection consumes:
- `sort_buffer_size` (256 KB default)
- `join_buffer_size` (256 KB default)
- `read_buffer_size` (128 KB default)
- `read_rnd_buffer_size` (256 KB default)
- `tmp_table_size` / `max_heap_table_size` (16 MB default per temp table)
- Thread stack (1 MB default)

At 155 connections, per-thread memory overhead is approximately **155 × ~2 MB = ~310 MB baseline**, with spikes when queries create temp tables or hash joins.

### CPU Utilization (14-Day Daily)

| Date       | Stage 8.0 Avg | Stage 8.0 Max | Stage 8.4 Avg | Stage 8.4 Max |
|------------|:-------------:|:-------------:|:-------------:|:-------------:|
| 2026-06-11 |     2.5%      |     34.9%     |     3.6%      |     29.9%     |
| 2026-06-12 |     2.5%      |     36.1%     |     3.6%      |     31.1%     |
| 2026-06-13 |     2.4%      |     38.4%     |     3.5%      |     43.5%     |
| 2026-06-14 |     2.6%      |     37.0%     |     3.7%      |     48.9%     |
| 2026-06-15 |     2.5%      |     40.0%     |     3.7%      |     43.8%     |
| 2026-06-16 |     2.5%      |     33.0%     |     3.6%      |     32.4%     |
| 2026-06-17 |     2.5%      |     36.9%     |     4.0%      |     72.0%     |
| 2026-06-18 |     2.5%      |     31.9%     |     3.6%      |     41.8%     |
| 2026-06-19 |     2.5%      |     41.4%     |     3.4%      |     38.3%     |
| 2026-06-20 |     2.4%      |     37.9%     |     3.4%      |     37.9%     |
| 2026-06-21 |     2.5%      |     37.0%     |     3.6%      |     42.5%     |
| 2026-06-22 |     2.6%      |     33.8%     |     3.5%      |     42.9%     |
| 2026-06-23 |     2.5%      |     30.9%     |     3.5%      |     54.4%     |
| 2026-06-24 |     2.5%      |     34.0%     |     3.6%      |     31.1%     |

**Stage 8.4 has 44% higher average CPU** (3.6% vs 2.5%) and higher peak spikes (**72% on June 17** vs 41.4% max on 8.0). The CPU spike on June 17 likely correlates with a period of high memory allocator activity.

### Disk I/O (Last 5 Days)

| Metric    | Stage 8.0 Avg | Stage 8.0 Max | Stage 8.4 Avg | Stage 8.4 Max |
|-----------|:-------------:|:-------------:|:-------------:|:-------------:|
| ReadIOPS  |      1.5      |      427      |     12.0      |     6,389     |
| WriteIOPS |     132.8     |    14,323     |     128.1     |    11,244     |

**Stage 8.4 ReadIOPS is 8x higher** (avg 12 vs 1.5), consistent with the buffer pool being full and needing to read from disk more often. The 6,389 max ReadIOPS on 8.4 indicates significant disk read bursts — likely during the stored procedure batch window when the buffer pool cannot satisfy all requests from cache.

---

## 6. Slow Query Log Analysis

### Configuration

| Setting           | Stage 8.0 | Stage 8.4      |
|-------------------|-----------|----------------|
| `slow_query_log`  | OFF       | ON             |
| `log_output`      | TABLE     | FILE           |
| `long_query_time` | 1.0s      | 1.0s (default) |
| Entries (TABLE)   | 0         | — (uses FILE)  |
| Log rotation      | —         | Hourly         |

### Stage 8.4 Slow Query Log Volume (3 Days Available)

| Date       | Log Files | Total Size | Biggest File Size | Biggest File Hour  |
|------------|:---------:|:----------:|:-----------------:|:------------------:|
| 2026-06-23 |     9     |   100 KB   |       12 KB       |       Hour 1       |
| 2026-06-24 |    24     |   7.6 MB   |      7.0 MB       | Hour 8 (02:00 UTC) |
| 2026-06-25 |    16     |   7.1 MB   |      6.7 MB       | Hour 8 (02:00 UTC) |

**Pattern:** The slow query surge occurs daily at **Hour 8 (02:00 UTC)** — this is the batch processing window where stored procedures and bulk operations run.

### Top Queries by Execution Time (Hour 8, June 25)

| Query Time | Rows Examined | Query                                                                                |
|-----------:|--------------:|--------------------------------------------------------------------------------------|
|     257.1s |             0 | `SELECT COUNT(1) FROM schedule_restore`                                              |
|      91.5s |             0 | `SELECT COUNT(1) FROM schedule`                                                      |
|      44.8s |             0 | `SELECT COUNT(1) FROM master_live_index_backup_20240117`                             |
|      29.9s |             0 | `SELECT COUNT(1) FROM master_autocommercial_index_backup_20240117`                   |
|      28.3s |    12,493,668 | `INSERT INTO master_content_index_to_delete SELECT ... FROM master_content_index...` |
|      20.4s |             0 | `SELECT COUNT(1) FROM tms_program_0102`                                              |
|      20.2s |             0 | `SELECT COUNT(1) FROM master_live_index_amoore_baseline`                             |
|      19.5s |             0 | `SELECT COUNT(1) FROM master_autocommercial_index2`                                  |

### Top Queries by Rows Examined (Memory-Heavy)

| Query Time | Rows Examined | Query                                           |
|-----------:|--------------:|-------------------------------------------------|
|       3.3s |    43,472,979 | `CALL build_live_persistence_audio(-1, ...)`    |
|       3.4s |    43,388,575 | `CALL build_live_persistence_audio(-1, ...)`    |
|       3.4s |    43,153,915 | `CALL build_live_persistence_audio(118, ...)`   |
|       3.3s |    43,153,915 | `CALL build_live_persistence_audio(1, ...)`     |
|       3.2s |    43,153,915 | `CALL build_live_persistence_audio(3, ...)`     |
|       3.3s |    43,153,915 | `CALL build_live_persistence_audio(13, ...)`    |
|       3.2s |    43,153,915 | `CALL build_live_persistence_audio(7, ...)`     |
|       3.3s |    43,153,915 | `CALL build_live_persistence_audio(113, ...)`   |
|       3.4s |    43,070,127 | `CALL build_live_persistence_audio(118, ...)`   |
|      28.3s |    12,493,668 | `INSERT INTO master_content_index_to_delete...` |

### Query Pattern Distribution (Hour 8, 121 Queries)

| Pattern                                         | Count | Memory Impact                                               |
|-------------------------------------------------|------:|-------------------------------------------------------------|
| `DELETE FROM master_content_index WHERE ...`    |    37 | Moderate — row-level deletes with IN clause                 |
| `UPDATE master_autocommercial_index INNER JOIN` |    25 | High — JOIN + UPDATE holds locks and temp buffers           |
| `CALL build_live_persistence_audio(...)`        |    14 | 🔴 Very High — 43M rows examined per call, drives HP_PTRS   |
| `CALL build_file_persistence(...)`              |    14 | 🔴 Very High — similar pattern                              |
| `SELECT ... FROM master_autocommercial_index`   |     4 | Moderate — large scans                                      |
| `SELECT COUNT(1) FROM ...`                      |     8 | High — full table scans of large/backup tables (up to 257s) |
| `INSERT INTO ... SELECT FROM ...`               |     1 | 🔴 Very High — 12.5M rows, generates large temp structures  |

### Hour 13 Analysis (Second-Busiest, 222 Queries)

| Query Time | Rows Examined | Query                                                               |
|-----------:|--------------:|---------------------------------------------------------------------|
|      10.7s |     3,280,699 | `SELECT tms_schedule.tf_database_key, ... CONCAT(STR_TO_DATE(...))` |
|       4.4s |     2,539,282 | `SELECT tms_schedule.tf_database_key, REPLACE(REPLACE(...))`        |
|       3.5s |    43,115,571 | `CALL build_live_persistence_audio(113, ...)`                       |
|       3.5s |    43,317,725 | `CALL build_live_persistence_audio(-1, ...)`                        |

The `build_live_persistence_audio` calls continue into non-batch hours, scanning 43M rows each.

---

## 7. Connecting the Dots — Memory Pressure Chain

```
                      25x more connections (155 vs 6)
                               │
                    ┌──────────┴──────────┐
                    │                     │
            Per-thread memory       Concurrent query
            (~310 MB baseline)      execution pressure
                    │                     │
                    │          ┌──────────┴──────────┐
                    │          │                     │
                    │    TempTable RAM           Hash Join Ptrs
                    │    peaked 7.3 GB          peaked 18.1 GB
                    │          │                     │
                    └──────────┴─────────────────────┘
                               │
                    Buffer pool saturated
                    (0.29% free, 255 wait_free)
                               │
                    ┌──────────┴──────────┐
                    │                     │
              Read-ahead evicted     FreeableMemory
              (21,511 pages)         declining 18.6 MB/day
                    │                     │
                    │              Projected ~42 days
                    │              to concerning level
                    │
              ReadIOPS up 8x
              (disk compensating for cache misses)
```

---

## 8. Risk Assessment

| Risk Factor                       | Severity | Likelihood | Impact                                        |
|-----------------------------------|----------|------------|-----------------------------------------------|
| Buffer pool exhaustion            | HIGH     | MEDIUM     | Query latency spikes, increased disk I/O      |
| TempTable RAM spike during batch  | HIGH     | HIGH       | Could trigger OOM if >8 GB during peak conns  |
| HP_PTRS spike during stored procs | CRITICAL | MEDIUM     | 18.1 GB peak + 22 GB buffer pool > 32 GB RAM  |
| FreeableMemory decline to <3 GB   | MEDIUM   | MEDIUM     | OS swapping begins, cascading performance hit |
| Single buffer pool instance mutex | MEDIUM   | ONGOING    | Latency tail on concurrent page requests      |

---

## 9. Recommendations

### Immediate (This Week)

| # | Action                                      | Rationale                                                         | Risk |
|---|---------------------------------------------|-------------------------------------------------------------------|------|
| 1 | Set `innodb_buffer_pool_instances = 8`      | Restore 8.0 behavior, distribute mutex load across 8 regions      | Low  |
| 2 | Set `temptable_max_ram = 1073741824` (1 GB) | Cap TempTable RAM to prevent 7.3 GB spikes; excess spills to disk | Low  |
| 3 | Review `build_live_persistence_audio` proc  | 43M row scans per call are the primary HP_PTRS driver             | None |
| 4 | Review `SELECT COUNT(1)` on backup tables   | 257s full table scan on `schedule_restore` wastes I/O             | None |

### Short-Term (Next 2 Weeks)

| # | Action                                            | Rationale                                                            | Risk   |
|---|---------------------------------------------------|----------------------------------------------------------------------|--------|
| 5 | Set `join_buffer_size = 262144` (verify)          | Reduce per-connection hash join memory; default may be higher on 8.4 | Low    |
| 6 | Add indexes to stored procedure join columns      | Reduce 43M row scans; indexes would eliminate hash joins             | Medium |
| 7 | Schedule batch procs during low-connection window | Avoid batch (02:00 UTC) + peak connections overlapping               | Low    |
| 8 | Monitor `wait_free` trend daily                   | Track if buffer pool stalls are increasing or stable                 | None   |

### Medium-Term (Next Month)

| #  | Action                                     | Rationale                                                       | Risk |
|----|--------------------------------------------|-----------------------------------------------------------------|------|
| 9  | Consider `db.r6i.2xlarge` (8 vCPU / 64 GB) | If memory pressure continues declining after tuning             | Cost |
| 10 | Profile connection pool sizing             | 155 avg connections may include idle connections wasting memory | Low  |
| 11 | Enable slow query log on Stage 8.0         | Establish baseline for direct query comparison                  | Low  |

---

## 10. Monitoring Queries

### Check Buffer Pool Wait-Free Trend
```sql
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_wait_free';
-- Run daily; any increase = active memory pressure
```

### Check TempTable RAM Usage
```sql
SELECT event_name,
       ROUND(CURRENT_NUMBER_OF_BYTES_USED/1024/1024, 1) AS current_MB,
       ROUND(HIGH_NUMBER_OF_BYTES_USED/1024/1024, 1) AS high_water_MB
FROM performance_schema.memory_summary_global_by_event_name
WHERE event_name LIKE '%temptable%';
```

### Check Hash Join Memory
```sql
SELECT event_name,
       ROUND(CURRENT_NUMBER_OF_BYTES_USED/1024/1024, 1) AS current_MB,
       ROUND(HIGH_NUMBER_OF_BYTES_USED/1024/1024, 1) AS high_water_MB
FROM performance_schema.memory_summary_global_by_event_name
WHERE event_name LIKE '%HP_PTRS%';
```

### CloudWatch CLI — FreeableMemory Spot Check
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeableMemory \
  --dimensions Name=DBInstanceIdentifier,Value=prod-rds-auxdb-stage-84-20260602 \
  --start-time $(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 --statistics Average Minimum \
  --region us-east-1
```
