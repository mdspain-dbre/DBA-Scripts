# MySQL Configuration Comparison

## Instances Compared

| Property       | Stage 8.4                                                                    | Prod 8.0                                                                    |
|----------------|------------------------------------------------------------------------------|-----------------------------------------------------------------------------|
| Endpoint       | prod-rds-auxdb-stage-84-20260602.cujpo2r0mujo.us-east-1.rds.amazonaws.com    | prod-rds-auxdb-80-20240903.cujpo2r0mujo.us-east-1.rds.amazonaws.com         |
| Engine Version | 8.4.5                                                                        | 8.0                                                                         |
| Instance Class | db.r6i.xlarge                                                                | db.r6i.xlarge                                                               |

---

## Full Variable Comparison

| Variable                       | Stage 8.4 Value | Stage MB | Prod 8.0 Value | Prod MB | Different?                      |
|--------------------------------|-----------------|----------|----------------|---------|:-------------------------------:|
| binlog_cache_size              | 32768           | 0.03     | 32768          | 0.03    |                                 |
| bulk_insert_buffer_size        | 8388608         | 8.00     | 8388608        | 8.00    |                                 |
| innodb_buffer_pool_instances   | 1               | —        | 8              | —       | 🔴 YES                           |
| innodb_change_buffer_max_size  | 25              | —        | 25             | —       |                                 |
| innodb_log_buffer_size         | 67108864        | 64.00    | 8388608        | 8.00    | 🔴 YES                           |
| innodb_sort_buffer_size        | 1048576         | 1.00     | 1048576        | 1.00    |                                 |
| join_buffer_size               | 262144          | 0.25     | 262144         | 0.25    |                                 |
| key_buffer_size                | 8388608         | 8.00     | 16777216       | 16.00   | 🔴 YES                           |
| max_heap_table_size            | 209715200       | 200.00   | 2000000000     | 1907.35 | 🔴 YES                           |
| net_buffer_length              | 16384           | 0.02     | 16384          | 0.02    |                                 |
| read_buffer_size               | 262144          | 0.25     | 262144         | 0.25    |                                 |
| read_rnd_buffer_size           | 524288          | 0.50     | 524288         | 0.50    |                                 |
| sort_buffer_size               | 262144          | 0.25     | 262144         | 0.25    |                                 |
| table_open_cache               | 8000            | —        | 8000           | —       |                                 |
| thread_cache_size              | 34              | —        | 100            | —       | 🔴 YES                           |
| tmp_table_size                 | 209715200       | 200.00   | 2000000000     | 1907.35 | 🔴 YES                           |

---

## Differences Detail

### 🔴 innodb_buffer_pool_instances

|       | Stage 8.4 | Prod 8.0 |
|-------|-----------|----------|
| Value | **1**     | **8**    |

- **Impact**: With only 1 buffer pool instance on stage, all buffer pool mutex contention funnels through a single instance. Prod splits across 8, reducing lock contention under concurrency.
- **Note**: MySQL 8.4 may handle this differently internally, but for a ~24 GB buffer pool on r6i.xlarge, multiple instances generally help under write-heavy concurrency.

---

### 🔴 innodb_log_buffer_size

|       | Stage 8.4              | Prod 8.0             |
|-------|------------------------|----------------------|
| Value | **67,108,864 (64 MB)** | **8,388,608 (8 MB)** |

- **Impact**: Stage has 8x the redo log buffer. This reduces the frequency of log flushes for large transactions, which is beneficial for write-heavy workloads.
- **Note**: This is likely a MySQL 8.4 default change (64 MB is the new default in 8.4 vs 8 MB in 8.0).

---

### 🔴 key_buffer_size

|       | Stage 8.4            | Prod 8.0               |
|-------|----------------------|------------------------|
| Value | **8,388,608 (8 MB)** | **16,777,216 (16 MB)** |

- **Impact**: MyISAM key cache. Low priority for InnoDB workloads. Prod has 2x but this is unlikely to matter unless MyISAM system tables are heavily accessed.

---

### 🔴 max_heap_table_size

|       | Stage 8.4                | Prod 8.0                    |
|-------|--------------------------|-----------------------------|
| Value | **209,715,200 (200 MB)** | **2,000,000,000 (~1.9 GB)** |

- **Impact**: Stage caps MEMORY engine tables and internal temp table sizing at 200 MB vs ~1.9 GB on prod. Under heavy GROUP BY / ORDER BY / DISTINCT workloads, stage will spill to disk much sooner.

---

### 🔴 tmp_table_size

|       | Stage 8.4                | Prod 8.0                    |
|-------|--------------------------|-----------------------------|
| Value | **209,715,200 (200 MB)** | **2,000,000,000 (~1.9 GB)** |

- **Impact**: Same effect as max_heap_table_size above — internal temp tables on stage are capped at 200 MB before spilling to disk. Prod allows ~1.9 GB per temp table in memory.

---

### 🔴 thread_cache_size

|       | Stage 8.4 | Prod 8.0 |
|-------|-----------|----------|
| Value | **34**    | **100**  |

- **Impact**: Prod caches more idle threads for reuse. With stage handling 140-220 connections, a thread cache of only 34 means more frequent thread creation/destruction overhead during connection bursts. Consider raising to at least 50-100 on stage.

---

## Summary

Six variables differ between the instances. The most operationally significant are:

1. **tmp_table_size / max_heap_table_size** — 10x lower on stage; causes earlier disk spills for heavy queries.
2. **innodb_buffer_pool_instances** — 1 on stage vs 8 on prod; potential mutex contention under write concurrency.
3. **thread_cache_size** — 34 vs 100; stage may see more thread churn at higher connection counts.
4. **innodb_log_buffer_size** — Stage is actually *better* here (64 MB vs 8 MB), likely from 8.4 defaults.

---


