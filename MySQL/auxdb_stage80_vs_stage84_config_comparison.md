# MySQL Configuration Comparison — Stage 8.0 vs Stage 8.4 vs Prod 8.0

## Instances Compared

| Property        | Stage 8.0                       | Stage 8.4                        | Prod 8.0                    |
|-----------------|---------------------------------|----------------------------------|-----------------------------|
| Endpoint        | prod-rds-auxdb-stage80-20240820 | prod-rds-auxdb-stage-84-20260602 | prod-rds-auxdb-80-20240903  |
| Engine Version  | 8.0.42                          | 8.4.5                            | 8.0.42                      |
| Instance Class  | db.r6i.xlarge                   | db.r6i.xlarge                    | db.r6i.4xlarge              |
| vCPUs / RAM     | 4 / ~32 GB                      | 4 / ~32 GB                       | 16 / ~128 GB                |
| Buffer Pool     | 23,622,320,128 (~22 GB)         | 23,622,320,128 (~22 GB)          | 98,784,247,808 (~92 GB)     |
| Parameter Group | aux-stg-8-0-*                   | aux-stg-8-4-5-apr-28             | aux-prod-prod-8-0-37-sep-03 |

---

## Full Variable Comparison

| Variable                      | Stage 8.0 Value | 8.0 MB | Stage 8.4 Value | 8.4 MB | Prod 8.0 Value | Prod MB |  Different?  |
|-------------------------------|-----------------|--------|-----------------|--------|----------------|---------|:------------:|
| binlog_cache_size             | 32768           | 0.03   | 32768           | 0.03   | 32768          | 0.03    |              |
| bulk_insert_buffer_size       | 8388608         | 8.00   | 8388608         | 8.00   | 8388608        | 8.00    |              |
| innodb_buffer_pool_instances  | 8               | —      | 8 ✅            | —      | 8              | —       | ✅ Fixed     |
| innodb_change_buffer_max_size | 25              | —      | 25              | —      | 25             | —       |              |
| innodb_log_buffer_size        | 8388608         | 8.00   | 67108864        | 64.00  | 8388608        | 8.00    | 🔴 8.4 only  |
| innodb_sort_buffer_size       | 1048576         | 1.00   | 1048576         | 1.00   | 1048576        | 1.00    |              |
| join_buffer_size              | 262144          | 0.25   | 262144          | 0.25   | 262144         | 0.25    |              |
| key_buffer_size               | 16777216        | 16.00  | 8388608         | 8.00   | 16777216       | 16.00   | 🔴 8.4 only  |
| max_heap_table_size           | 209715200       | 200.00 | 209715200       | 200.00 | 2000000000     | 1907.35 | 🟡 Stage gap |
| net_buffer_length             | 16384           | 0.02   | 16384           | 0.02   | 16384          | 0.02    |              |
| read_buffer_size              | 262144          | 0.25   | 262144          | 0.25   | 262144         | 0.25    |              |
| read_rnd_buffer_size          | 524288          | 0.50   | 524288          | 0.50   | 524288         | 0.50    |              |
| sort_buffer_size              | 262144          | 0.25   | 262144          | 0.25   | 262144         | 0.25    |              |
| table_open_cache              | 8000            | —      | 8000            | —      | 8000           | —       |              |
| thread_cache_size             | 34              | —      | 34              | —      | 100            | —       | 🟡 Stage gap |
| tmp_table_size                | 209715200       | 200.00 | 209715200       | 200.00 | 2000000000     | 1907.35 | 🟡 Stage gap |

**Legend:** 🔴 = MySQL 8.4 default regression (action recommended) · 🟡 = Stage vs Prod parameter group gap (pre-existing, not a migration issue) · ✅ = Remediated

---

## 8.4 Regressions (Action Recommended)

### ✅ innodb_buffer_pool_instances (REMEDIATED 2026-06-26)

|       | Stage 8.0 | Stage 8.4 | Prod 8.0 |
|-------|-----------|-----------|----------|
| Value | **8**     | **8** ✅  | **8**    |

**Status:** Parameter group `aux-stg-8-4-5-apr-28` updated to `innodb_buffer_pool_instances=8` and both the primary (`prod-rds-auxdb-stage-84-20260602`) and replica (`-replica`) have been rebooted to apply. Verified live: `bp_instances=8`, `page_cleaners=8` (cascading default).

#### Historical context (pre-fix value was 1)

#### Why it changed

MySQL 8.4 ([WL #16179](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)) replaced the fixed default of 8 with a dynamic formula:

> If `innodb_buffer_pool_size > 1 GiB`, the default is the **minimum** of:
> - **Buffer pool hint**: `½ × (innodb_buffer_pool_size / innodb_buffer_pool_chunk_size)`
> - **CPU hint**: `¼ × available_logical_processors`
> - Clamped to 1–64.

On an **RDS db.r6i.xlarge** (4 vCPUs):
- Buffer pool hint = ½ × (22 GB / 128 MB) = ½ × 176 = **88** (capped to 64)
- CPU hint = ¼ × 4 = **1**
- Result: **min(64, 1) = 1**

So the value of 1 is not a misconfiguration — it's the new formula resolving to 1 because RDS only exposes 4 vCPUs.

Note: On Prod (db.r6i.4xlarge, 16 vCPUs), the same formula on 8.4 would yield `¼ × 16 = 4`, so a prod 8.4 migration would land on 4 instances — still less than the current 8.

#### What `innodb_buffer_pool_instances` controls

Each buffer pool instance manages its own:
- **Free list** — available pages for new data
- **Flush list** — dirty pages awaiting write-back
- **LRU list** — eviction ordering
- **Buffer pool mutex** — protects all of the above

With `instances = 1`, all concurrent threads compete for a **single mutex** on every buffer pool page access. With `instances = 8`, the 22 GB pool is divided into 8 × ~2.75 GB regions, each with its own mutex — reducing contention by ~8×.

#### Cascading effects

| Dependent Variable         | With instances=1                    | With instances=8                      |
|----------------------------|-------------------------------------|---------------------------------------|
| `innodb_page_cleaners`     | Defaults to 1                       | Defaults to 8                         |
| `innodb_doublewrite_files` | 2 files (2 × 1)                     | 16 files (2 × 8)                      |
| `innodb_lru_scan_depth`    | 1,024 pages/sec total LRU scan work | 1,024 × 8 = 8,192 total LRU scan work |

The `innodb_page_cleaners` drop is particularly important: with only 1 page cleaner thread, dirty page flushing is single-threaded. Under write-heavy workloads (the `UPDATE master_autocommercial_index` pattern in the slow query analysis), this becomes a bottleneck.

#### Impact on this workload

From the [slow query analysis](auxdb_stage84_slow_query_analysis_20260625.md):
- 25 concurrent `UPDATE master_autocommercial_index` queries (342s total) all contend for the same buffer pool pages
- 54 `build_live_persistence_audio` calls examine 43M rows — all flushing through a single page cleaner
- The `innodb_buffer_pool_instances = 1` amplifies mutex contention for all of these

#### Recommendation (APPLIED)

Set `innodb_buffer_pool_instances = 8` explicitly in the Stage 8.4 RDS parameter group. This:
1. Matches the Stage 8.0 and Prod 8.0 configuration
2. Restores 8 page cleaner threads for parallel dirty page flushing
3. Reduces buffer pool mutex contention for the 25 concurrent UPDATE writers
4. Is the MySQL-recommended minimum for pools > 1 GB

The MySQL 8.4 internal buffer pool mutex structure did not change — only the default calculation changed. The new formula landed on 1 because it keys off vCPU count (`¼ × 4 = 1`), which is a conservative general-purpose heuristic that does not account for workload concurrency. With 25 concurrent `UPDATE` writers hitting the same buffer pool pages, a single mutex is a real bottleneck regardless of MySQL version.

| Value | Rationale                                                                                                  |
|-------|------------------------------------------------------------------------------------------------------------|
| **1** | MySQL 8.4 default for 4 vCPUs. Fine for read-mostly or low-concurrency workloads                           |
| **4** | One per vCPU. Reduces contention without over-partitioning relative to CPU count                           |
| **8** | Matches 8.0 default and existing prod/stage config. Each instance = ~2.75 GB (well above the 1 GB minimum) |

**8 is the safest choice** because it is a known-good configuration already running on Stage 8.0 and Prod 8.0, and changing one variable at a time makes it easier to isolate 8.4 upgrade effects. If desired, benchmarking with 4 later could determine whether fewer instances match throughput with less memory fragmentation — but that is optimization, not a migration concern.

> **Note**: This is a **static variable** — changing it requires a parameter group modification and an RDS instance **reboot** (not just apply-immediately). Plan for a maintenance window.

---

### 🔴 innodb_log_buffer_size

|       | Stage 8.0            | Stage 8.4              | Prod 8.0             |
|-------|----------------------|------------------------|----------------------|
| Value | **8,388,608 (8 MB)** | **67,108,864 (64 MB)** | **8,388,608 (8 MB)** |

- **Impact**: Stage 8.4 has 8× the redo log buffer of both 8.0 instances, reducing the frequency of log flushes for large transactions. This is beneficial for write-heavy workloads.
- **Note**: This is a MySQL 8.4 default change (64 MB vs 8 MB in 8.0). The larger buffer is an improvement — no action needed. Prod will pick this up automatically when migrated to 8.4.

---

### 🔴 key_buffer_size

|       | Stage 8.0              | Stage 8.4            | Prod 8.0               |
|-------|------------------------|----------------------|------------------------|
| Value | **16,777,216 (16 MB)** | **8,388,608 (8 MB)** | **16,777,216 (16 MB)** |

- **Impact**: MyISAM key cache. Stage 8.4 has half the value of both 8.0 instances. Low priority for InnoDB workloads — unlikely to matter unless MyISAM system tables are heavily accessed.
- **Note**: MySQL 8.4 lowered the default from 16 MB to 8 MB. No action needed for InnoDB-only workloads.

---

## Stage vs Prod Parameter Group Gaps (Pre-existing)

These variables are **identical between Stage 8.0 and Stage 8.4** (so not a migration regression) but differ from Prod. They reflect a pre-existing gap between the stage and prod parameter groups.

### 🟡 max_heap_table_size

|       | Stage 8.0                | Stage 8.4                | Prod 8.0                    |
|-------|--------------------------|--------------------------|-----------------------------|
| Value | **209,715,200 (200 MB)** | **209,715,200 (200 MB)** | **2,000,000,000 (~1.9 GB)** |

- **Impact**: Caps the maximum size of MEMORY (HEAP) engine tables and is the ceiling for `tmp_table_size`. Stage is **10× smaller** than prod. Queries that build large in-memory temp tables will spill to disk-based TempTable on stage but stay in RAM on prod.
- **Note**: Stage 8.4 inherited this from the stage 8.0 parameter group — not a 8.4 regression. Consider aligning stage with prod if testing workloads that depend on large temp tables.

---

### 🟡 tmp_table_size

|       | Stage 8.0                | Stage 8.4                | Prod 8.0                    |
|-------|--------------------------|--------------------------|-----------------------------|
| Value | **209,715,200 (200 MB)** | **209,715,200 (200 MB)** | **2,000,000,000 (~1.9 GB)** |

- **Impact**: Maximum size of in-memory internal temp tables before spilling to disk. Combined with `max_heap_table_size`, this is what governs whether `Created_tmp_disk_tables` increments. The slow query analysis shows stage is creating significant numbers of disk temp tables — partly attributable to this 10× lower cap.
- **Note**: Same root cause as `max_heap_table_size` above. Aligning stage with prod (1.9 GB) would reduce disk-temp-table spills during stage testing.

---

### 🟡 thread_cache_size

|       | Stage 8.0 | Stage 8.4 | Prod 8.0 |
|-------|-----------|-----------|----------|
| Value | **34**    | **34**    | **100**  |

- **Impact**: Number of threads kept cached for reuse instead of being torn down/recreated per connection. Lower value = more thread create/destroy overhead under connection churn. Prod sustains higher connection rates so the larger cache reduces thread creation cost.
- **Note**: Low priority — performance impact is small unless the workload has high connection churn. Stage 8.4 currently averages 155 connections so a higher cache would marginally help.

---

## Notable Matches

These variables are **identical across all three instances**, confirming the core parameter group settings carried over correctly:

| Variable                      | Value   | MB   | Notes                 |
|-------------------------------|---------|------|-----------------------|
| binlog_cache_size             | 32768   | 0.03 | Standard              |
| bulk_insert_buffer_size       | 8388608 | 8.00 | Standard              |
| innodb_change_buffer_max_size | 25      | —    | Standard (percentage) |
| innodb_sort_buffer_size       | 1048576 | 1.00 | Standard              |
| join_buffer_size              | 262144  | 0.25 | Standard              |
| net_buffer_length             | 16384   | 0.02 | Standard              |
| read_buffer_size              | 262144  | 0.25 | Standard              |
| read_rnd_buffer_size          | 524288  | 0.50 | Standard              |
| sort_buffer_size              | 262144  | 0.25 | Standard              |
| table_open_cache              | 8000    | —    | Standard              |

---

## Summary

Six variables differ across the three instances, split into two categories:

### MySQL 8.4 Default Changes (Stage 8.4 only)

| # | Variable                     | 8.0 Value | 8.4 Value | Action                          |
|---|------------------------------|-----------|-----------|---------------------------------|
| 1 | innodb_buffer_pool_instances | 8         | 8 ✅      | ✅ Remediated 2026-06-26        |
| 2 | innodb_log_buffer_size       | 8 MB      | 64 MB     | ✅ Improvement — keep           |
| 3 | key_buffer_size              | 16 MB     | 8 MB      | ✅ Negligible for InnoDB — keep |

### Stage vs Prod Parameter Group Gaps (Pre-existing)

| # | Variable            | Stage Value | Prod Value | Action                                         |
|---|---------------------|-------------|------------|------------------------------------------------|
| 4 | max_heap_table_size | 200 MB      | 1.9 GB     | 🟡 Align stage with prod for realistic testing |
| 5 | tmp_table_size      | 200 MB      | 1.9 GB     | 🟡 Align stage with prod for realistic testing |
| 6 | thread_cache_size   | 34          | 100        | 🟡 Low-priority alignment                      |

**Key observation**: The only true 8.4 migration regression requiring action was `innodb_buffer_pool_instances`, which has now been remediated (param group set to 8, primary + replica rebooted 2026-06-26). The other 8.4 differences are either improvements or negligible. The stage-vs-prod gaps (`tmp_table_size`, `max_heap_table_size`, `thread_cache_size`) pre-date the 8.4 work and represent a parameter group alignment opportunity, not a migration issue.

---
