# Memory Pressure Investigation Report

## RDS MySQL Instances — Inscape Production US 1 (788724168120)

| Property               | Instance 84                        | Instance 80                        |
|------------------------|------------------------------------|------------------------------------|
| **Identifier**         | prod-rds-auxdb-qa-84-20260226      | prod-rds-auxdb-qa-80-20240808      |
| **Engine**             | MySQL 8.4.5                        | MySQL 8.0.42                       |
| **Instance Class**     | db.r6i.xlarge (32 GB RAM)          | db.r6i.xlarge (32 GB RAM)          |
| **Storage**            | 300 GB                             | 300 GB                             |
| **Multi-AZ**           | Yes                                | No                                 |
| **Backup Window**      | 04:57–05:27 UTC                    | 04:57–05:27 UTC                    |
| **Maintenance Window** | Mon 10:00–10:30 UTC                | Mon 10:00–10:30 UTC                |
| **Buffer Pool**        | 75% of instance memory (~24 GB)    | 75% of instance memory (~24 GB)    |
| **Parameter Group**    | aux-qa-8-4-5-feb-26-readonly       | aux-qa-8-0-37-aug-24               |
| **Investigation Dates**| June 4–7, 2026                     | June 1–3, 2026                     |

---

## Executive Summary

**Finding: Memory pressure on both instances is a steady-state condition, NOT a one-time anomaly.** Comparison with two prior same-weekday periods shows identical patterns within normal variance. The buffer pool is configured at 75% of instance memory, leaving ~3.7–4.5 GB free — consistent with MySQL RDS best practices for this workload level.

The primary performance concern is NOT memory pressure but rather **a full-table-scan query running every 5 minutes** on instance 84 that examines 7.4 million rows per execution.

---

## 1. Metric Summary Tables

### Instance 84 — FreeableMemory (db.r6i.xlarge = 32 GB)

| Period                         | Avg Free | Min Free | Min Timestamp    | Max Free |
|--------------------------------|----------|----------|------------------|----------|
| **Jun 4–7 (Investigation)**    | 3.81 GB  | 3.72 GB  | 2026-06-07T11:30 | 3.86 GB  |
| May 28–31 (Prior Wk1)         | 3.84 GB  | 3.74 GB  | 2026-05-30T20:10 | 3.90 GB  |
| May 21–24 (Prior Wk2)         | 3.87 GB  | 3.77 GB  | 2026-05-24T11:35 | 3.96 GB  |

**Δ Investigation vs Prior Avg:** −30 MB avg, −50 MB min — within normal variance. No anomaly.

### Instance 84 — Key Metrics Comparison

| Metric                   | Jun 4–7 Avg | Jun 4–7 Max | May 28–31 Avg | May 21–24 Avg |
|--------------------------|-------------|-------------|---------------|---------------|
| CPUUtilization           | 1.8%        | 32.4%       | 1.8%          | 1.9%          |
| DatabaseConnections      | 27.7        | 46          | 22.7          | 29.5          |
| ReadIOPS                 | 6.5         | 1,512       | 6.5           | 6.6           |
| ReadLatency              | 0.21 ms     | 26.94 ms    | 0.19 ms       | 0.18 ms       |
| WriteIOPS                | 30.3        | 3,146       | 29.0          | 33.7          |
| SwapUsage                | **0 MB**    | **0 MB**    | 0 MB          | 0 MB          |
| NetworkReceiveThroughput | 0.04 MB/s   | 8.16 MB/s   | 0.04 MB/s     | 0.04 MB/s     |
| DiskQueueDepth           | 0.2         | 36.7        | 0.2           | 0.2           |

### Instance 80 — FreeableMemory (db.r6i.xlarge = 32 GB)

| Period                         | Avg Free | Min Free | Min Timestamp    | Max Free |
|--------------------------------|----------|----------|------------------|----------|
| **Jun 1–3 (Investigation)**    | 4.47 GB  | 4.16 GB  | 2026-06-02T11:35 | 4.51 GB  |
| May 25–27 (Prior Wk1)         | 4.49 GB  | 4.24 GB  | 2026-05-26T11:35 | 4.54 GB  |
| May 18–20 (Prior Wk2)         | 4.49 GB  | 4.14 GB  | 2026-05-20T11:35 | 4.54 GB  |

**Δ Investigation vs Prior Avg:** −20 MB avg — identical pattern. No anomaly.

### Instance 80 — Key Metrics Comparison

| Metric                   | Jun 1–3 Avg | Jun 1–3 Max | May 25–27 Avg | May 18–20 Avg |
|--------------------------|-------------|-------------|---------------|---------------|
| CPUUtilization           | 1.4%        | 30.1%       | 1.4%          | 1.4%          |
| DatabaseConnections      | 2.0         | 3           | 2.0           | 2.0           |
| ReadIOPS                 | 0.6         | 231         | 19.0          | 0.6           |
| ReadLatency              | 0.19 ms     | 14.94 ms    | 0.23 ms       | 0.22 ms       |
| WriteIOPS                | 31.4        | 3,034       | 33.1          | 31.4          |
| SwapUsage                | 0.7 MB      | 0.7 MB      | 0.7 MB        | 0.7 MB        |
| NetworkReceiveThroughput | 0.02 MB/s   | 6.99 MB/s   | 0.02 MB/s     | 0.02 MB/s     |
| DiskQueueDepth           | 0.2         | **53.8**    | 0.3           | 0.2           |

---

## 2. Daily Memory Pressure Timeline

### Recurring Daily Spike Pattern (Both Instances)

Both instances exhibit a **consistent daily performance spike at 11:25–11:40 UTC** that is NOT the RDS automated backup (which runs at 04:57 UTC). This pattern is identical across all investigated periods.

#### Instance 84 — Lowest FreeableMemory Hours (Jun 4–7)

| Timestamp (UTC)  | FreeableMemory           |
|------------------|--------------------------|
| 2026-06-07T11:xx | 3.718 GB ← Daily minimum |
| 2026-06-05T20:xx | 3.740 GB                 |
| 2026-06-06T09:xx | 3.742 GB                 |
| 2026-06-05T23:xx | 3.746 GB                 |
| 2026-06-06T11:xx | 3.757 GB                 |

#### Instance 84 — Highest CPU Hours (Jun 4–7)

| Timestamp (UTC)  | CPU Max |
|------------------|---------|
| 2026-06-06T11:xx | 32.4%   |
| 2026-06-05T11:xx | 31.8%   |
| 2026-06-04T11:xx | 30.8%   |
| 2026-06-07T11:xx | 30.7%   |
| 2026-06-04T09:xx | 16.6%   |

#### Instance 80 — Lowest FreeableMemory Hours (Jun 1–3)

| Timestamp (UTC)  | FreeableMemory           |
|------------------|--------------------------|
| 2026-06-02T11:xx | 4.157 GB ← Daily minimum |
| 2026-06-03T11:xx | 4.280 GB                 |
| 2026-06-01T11:xx | 4.321 GB                 |

**Conclusion:** The 11:25–11:40 UTC spike is a scheduled operation that runs daily on both instances. It drives WriteIOPS to ~3,000+, DiskQueueDepth to 36–54, and CPU to ~30%. This correlates with the RDS maintenance window style but occurs daily (not just Mondays).

---

## 3. Slow Query Log Analysis

> **Note:** Historical slow query logs for the investigation window (June 1–7) have been rotated out of RDS (retention ~7 days). Analysis below uses current logs which are representative since the workload pattern is provably recurring (identical across all 3 weeks examined). Instance 80 has slow_query_log disabled (default 10s threshold).

### Instance 84 — Top Slow Query Offenders

| #   | Query Pattern                                      | Source IP      | Frequency    | Avg Query Time | Rows Examined   | Database  |
|-----|----------------------------------------------------|----------------|--------------|----------------|-----------------|-----------|
| 1   | `SELECT Count(ifq.state)...FROM ingest_file_queue` | 172.17.13.228  | Every ~5 min | 1.13 sec       | **7,421,269**   | ingest_qa |
| 2   | `CALL build_file_persistence(-1, @success)`        | 172.17.37.165  | Every ~30 min| 1.05 sec       | 1,029,585       | ingest_qa |
| 3   | `CALL build_file_persistence(1, @success)`         | 172.17.37.165  | Every ~30 min| 1.05 sec       | 1,029,587       | ingest_qa |
| 4   | `CALL build_file_persistence(2, @success)`         | 172.17.37.165  | Every ~30 min| 1.05 sec       | 778,403         | ingest_qa |

### Query #1 Analysis (Primary Offender)

```sql
SELECT Count(ifq.state) AS cnt, s.state
FROM
    (SELECT 'pending' AS state
     UNION ALL
     SELECT 'ingesting' AS state) AS s
    LEFT JOIN ingest_file_queue ifq
    ON CONVERT(s.state USING utf8) = ifq.state
    AND last_update >= Date(Now() - INTERVAL 1 DAY)
GROUP BY s.state;
```

**Impact Assessment:**
- **Full table scan** of 7.4M rows on every execution (no usable index on `state` + `last_update`)
- Runs **288 times/day** (every 5 minutes)
- Total daily scan volume: **2.14 billion rows examined/day**
- `CONVERT(s.state USING utf8)` prevents index usage on the JOIN predicate
- This query monopolizes buffer pool pages, evicting other cached data

### Query #2–4 Analysis (`build_file_persistence`)

- Stored procedure called with parameters -1, 1, 2 in sequence
- Examines ~778K–1M rows per call
- Runs every 30 minutes (48 times/day)
- Lower individual impact but cumulatively significant

---

## 4. Source Service Identification

### IP-to-Service Mapping

| Source IP     | EC2 Instance ID     | Instance Name            | Type       | Service               | Function                  | Security Group             | Repo/IaC                   |
|---------------|---------------------|--------------------------|------------|-----------------------|---------------------------|----------------------------|----------------------------|
| 172.17.13.228 | i-01631376281252fc0 | control-plane-monitor    | c5.4xlarge | control-plane-monitor | infrastructure/monitoring | prod-control-plane-monitor | — (fixed instance, no ASG) |
| 172.17.37.165 | i-020c66a36fcab11c4 | control-plane-dts-qa-iad | t3.small   | control-plane-dts     | data-processing           | prod-control-plane-dts     | [control-plane-dts][1]     |

[1]: https://github.com/CognitiveNetworks/control-plane-dts

### Service Details

#### control-plane-monitor (172.17.13.228)
- **Purpose:** Infrastructure monitoring service
- **Query:** Polls `ingest_file_queue` table state every 5 minutes to count pending/ingesting items
- **Instance Type:** c5.4xlarge (fixed, not in ASG)
- **Environment:** prod
- **Team:** ops
- **Launched:** 2023-11-27

#### control-plane-dts-qa-iad (172.17.37.165)
- **Purpose:** Data Transfer Service (DTS) — file persistence processing
- **Query:** Calls `build_file_persistence` stored procedure with file type parameters
- **Instance Type:** t3.small
- **ASG:** `control-plane-dts-qa-iad` (Min=1, Max=1, Desired=1 — fixed capacity)
- **Environment:** stage/qa
- **Team:** inscape-ops
- **Launched:** 2025-09-02
- **Repo:** https://github.com/CognitiveNetworks/control-plane-dts
- **IaC Repo:** https://github.com/CognitiveNetworks/control-plane-dts

---

## 5. EventBridge Scheduled Rules

| Rule Name                        | Schedule     | State       | Target                                        | Relevance                                         |
|----------------------------------|--------------|-------------|-----------------------------------------------|---------------------------------------------------|
| overwatch-hour-qa-trigger        | rate(11 min) | ENABLED     | Lambda: overwatch-hour-qa `{"ZOO":"qa"}`      | May trigger monitoring that cascades to DB queries |
| overwatch-hour-dtsstage-trigger  | rate(11 min) | ENABLED     | Lambda: overwatch-hour-dtsstage `{"ZOO":"dtsstage"}` | Related to DTS stage environment            |
| cn_sessions_dai_queue_check      | rate(1 min)  | **DISABLED**| —                                             | Previously checked queue; now disabled             |

> The 5-minute polling from `control-plane-monitor` is not driven by EventBridge — it's likely an internal cron/scheduler within the EC2 instance itself.

---

## 6. Auto-Scaling Group Configuration

### control-plane-dts-qa-iad

| Property         | Value                              |
|------------------|------------------------------------|
| Min Size         | 1                                  |
| Max Size         | 1                                  |
| Desired Capacity | 1                                  |
| Launch Template  | lt-05dc1cd65242d0c0f (v7)          |
| AZ               | us-east-1c                         |
| Current Instance | i-020c66a36fcab11c4 (InService)    |

**Assessment:** Fixed at 1 instance — no auto-scaling variability. The ASG is used purely for self-healing (instance replacement on failure), not for scaling. This service does not contribute to variable load.

---

## 7. RDS Events

> **Note:** RDS events older than 14 days are not available via the describe-events API. The investigation windows (June 1–7) exceed this retention period. No events could be retrieved.

---

## 8. Methodology

### How Repos/Services Were Identified

1. **Slow query log** → Extracted source IPs from `User@Host` field
2. **`aws ec2 describe-network-interfaces`** → Mapped private IPs to ENIs and attached EC2 instance IDs
3. **`aws ec2 describe-instances`** → Retrieved full tag set including `Name`, `service`, `repo`, `iac-repo`, `function`, `team`, and `aws:autoscaling:groupName`
4. **`aws autoscaling describe-auto-scaling-groups`** → Confirmed ASG configuration for scaling-relevant instances

### Metric Collection

- **Granularity:** 5-minute (300s period) — 1-minute data expired (CloudWatch retains 1-min for 15 days only; investigation window is 16–19 days old)
- **Comparison:** Same weekday pattern: investigation window vs. prior 2 weeks on identical days-of-week
- **Metrics:** CPUUtilization, DatabaseConnections, ReadIOPS, ReadLatency, WriteIOPS, FreeableMemory, SwapUsage, NetworkReceiveThroughput, DiskQueueDepth

### Limitations

- Slow query logs rotated beyond 7-day RDS retention; current-day logs used (workload confirmed recurring)
- Instance 80 has `slow_query_log` disabled (default 10s threshold) — no query-level visibility
- RDS events unavailable beyond 14-day retention
- 1-minute granularity unavailable; 5-minute used instead

---

## 9. Root Cause Analysis

### Is This an Anomaly?

**No.** The memory and performance patterns are **identical** across all three weeks examined (investigation + 2 prior same-weekdays). The variance between periods is < 100 MB on FreeableMemory and < 2% on CPU — well within normal operating noise.

### What Causes the Memory Pressure?

| Factor                                    | Impact                                                                         |
|-------------------------------------------|--------------------------------------------------------------------------------|
| InnoDB Buffer Pool at 75% of RAM (~24 GB) | Expected: leaves ~4–5 GB for OS, temp tables, connections, sort buffers        |
| 7.4M row full-scan query every 5 min      | Forces constant buffer pool page cycling; evicts warm pages                    |
| Daily 11:25 UTC scheduled operation       | Causes transient additional memory allocation (~100–300 MB dip)                |
| ~28 active connections on instance 84     | Each connection allocates per-thread buffers (sort_buffer, join_buffer, etc.)   |

### Why Instance 84 Has Less Free Memory Than Instance 80

| Instance 84                             | Instance 80                |
|-----------------------------------------|----------------------------|
| 28 avg connections                      | 2 avg connections          |
| Active slow queries (5-min poll + DTS)  | Minimal application load   |
| Multi-AZ (replication overhead)         | Single-AZ                  |
| Free: 3.81 GB avg                       | Free: 4.47 GB avg          |

The ~660 MB difference is explained by connection overhead and replication buffers.

---

## 10. Actionable Next Steps

### Immediate (High Impact, Low Risk)

1. **Add composite index to `ingest_file_queue`:**
   ```sql
   ALTER TABLE ingest_qa.ingest_file_queue
   ADD INDEX idx_state_last_update (state, last_update);
   ```
   This should reduce the 7.4M row full-scan to an index-seek. Expected improvement: query time from 1.1s → <10ms.

2. **Fix the CONVERT() anti-pattern in the monitoring query:**
   Remove `CONVERT(s.state USING utf8)` — if collation mismatch exists, fix the column collation instead. The CONVERT prevents any index usage.

3. **Enable slow_query_log on Instance 80:**
   Set `long_query_time = 1` and `slow_query_log = 1` in parameter group `aux-qa-8-0-37-aug-24` to gain query visibility.

### Medium-Term (Architectural)

4. **Reduce polling frequency on control-plane-monitor:**
   The state-check query runs every 5 minutes. Consider:
   - Increasing interval to 15–30 minutes if real-time state isn't critical
   - Using a Redis/Memcached counter updated by the ingest service instead of polling the DB

5. **Investigate the 11:25 UTC daily spike:**
   The source is not RDS backup (04:57 UTC) or maintenance window (Mon 10:00). Check:
   - MySQL Event Scheduler: `SHOW EVENTS FROM ingest_qa;`
   - Cron jobs on the RDS-connected EC2 instances
   - Any Lambda/Step Functions triggered around that time

6. **Publish slow query logs to CloudWatch Logs:**
   Enable log export for `slowquery` in the RDS instance configuration for longer retention and historical analysis capability.

### Low Priority (Optimization)

7. **Review `build_file_persistence` stored procedure:**
   Scanning 778K–1M rows per call suggests missing or suboptimal indexes within the procedure's internal queries.

8. **Consider buffer pool size adjustment:**
   Current 75% is standard but with only 3.7 GB headroom and no swap usage, the system is stable. No change recommended unless connections grow.

---

## 11. Data Files Reference

All raw CloudWatch metric JSON files are stored in:
```
/Users/michael.dspain/Documents/DBA-Scripts/PromptScriptsOutput/80-84-comp/
```

| File Pattern            | Contents                                  |
|-------------------------|-------------------------------------------|
| `84_*_jun4-7.json`     | Instance 84 metrics, investigation window |
| `84_*_may28-31.json`   | Instance 84 metrics, prior week 1         |
| `84_*_may21-24.json`   | Instance 84 metrics, prior week 2         |
| `80_*_jun1-3.json`     | Instance 80 metrics, investigation window |
| `80_*_may25-27.json`   | Instance 80 metrics, prior week 1         |
| `80_*_may18-20.json`   | Instance 80 metrics, prior week 2         |
| `84_slowquery_*.log`   | Current slow query logs (instance 84)     |

---

*Report generated: 2026-06-23 | Analyst: DBA Automation | Account: Inscape Production US 1 (788724168120)*
