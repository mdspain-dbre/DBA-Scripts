# Aurora PostgreSQL Incident Investigation — ims-account-aurora-global-cluster

**Incident window:** 2026-09-11 22:00 UTC → 2026-09-12 01:00 UTC (16:00 → 19:00 MDT Fri 9/11)
**Account:** 889059331444 (`iam-account-prod`)
**Global cluster:** `ims-account-aurora-global-cluster`
**Writer region during incident:** us-west-2, cluster `ims-account-aurora-us-west-2-cluster`
**Engine:** aurora-postgresql 16.6
**Report generated:** 2026-09-15

---

## Executive summary

At 22:38 UTC on 2026-09-11, the writer instance `ims-account-aurora-us-west-2-cluster-0` hit CPU saturation (peak **99.8%**) with a connection storm to **4,504 sessions** and commit latency spiking to **57 ms** (baseline < 1 ms). The instance became unresponsive enough that at **00:14:55 UTC on 2026-09-12 Aurora initiated an unassisted cross-AZ failover** to `ims-account-aurora-us-west-2-cluster-2`, completing in ~21 seconds. **Recovery was driven by the RDS failover, not the Content Services team disconnecting at 00:10 UTC** — that likely helped bleed load but Aurora's health monitor made the call.

**Root cause of the connection/CPU spike cannot be identified from AWS forensics** because:

1. Performance Insights is **disabled** on every cluster member (default off, never turned on)
2. The cluster uses the **AWS-managed default parameter group** `default.aurora-postgresql16`, which is immutable and has `log_min_duration_statement`, `log_connections`, and `log_disconnections` all off
3. PostgreSQL logs for the incident window have **already rotated out** — earliest retained log is `2026-09-12-18` (~20 hours after recovery); default `rds.log_retention_period` is 3 days

Fixing these three configuration gaps is the primary next-step recommendation regardless of what caused this specific spike, because the next incident will be equally un-diagnosable until they're fixed.

---

## Timeline

| UTC                     | MDT          | Event                                                                        | Evidence                                                             |
|-------------------------|--------------|------------------------------------------------------------------------------|----------------------------------------------------------------------|
| 2026-09-11 22:38        | 16:38        | CPU + DatabaseConnections spike begins on cluster-0 (then-writer)            | CloudWatch AWS/RDS metrics (`metrics/*cluster-0*`)                   |
| 2026-09-11 23:00        | 17:00        | First page                                                                   | Provided incident timeline                                           |
| 2026-09-11 23:30        | 17:30        | Second page                                                                  | Provided incident timeline                                           |
| 2026-09-12 00:10        | 18:10        | Content Services severed application connections to the cluster              | Provided incident timeline                                           |
| **2026-09-12 00:14:55** | **18:14:55** | **RDS initiated cross-AZ failover: cluster-0 → cluster-2**                   | RDS event on cluster (`rds-events/cluster-us-west-2.json`)           |
| 2026-09-12 00:14:57     | 18:14:57     | `max_wal_senders` auto-adjusted 10 → 20 on cluster-2 (promotion side effect) | RDS event on cluster-2                                               |
| 2026-09-12 00:15:06     | 18:15:06     | cluster-2 restarted as new writer                                            | RDS event on cluster-2                                               |
| 2026-09-12 00:15:10     | 18:15:10     | cluster-0 acknowledged demotion, restarting as reader                        | RDS event on cluster-0                                               |
| 2026-09-12 00:15:16     | 18:15:16     | RDS-initiated failover marked complete                                       | RDS event on cluster                                                 |
| 2026-09-12 00:15:19     | 18:15:19     | cluster-0 back online as reader                                              | RDS event on cluster-0                                               |
| 2026-09-12 00:20        | 18:20        | Application services report healthy (post-reconnect settle)                  | Provided incident timeline                                           |

The RDS failover started **4 minutes 55 seconds after** Content Services stopped connecting, which suggests the disconnect helped Aurora's health checks pass a threshold. But the recovery action itself was Aurora's, not manual.

---

## Cluster topology at incident time vs now

| Instance                                 | Role during incident | Role now   |
|------------------------------------------|----------------------|------------|
| `ims-account-aurora-us-west-2-cluster-0` | **writer**           | reader     |
| `ims-account-aurora-us-west-2-cluster-1` | reader               | reader     |
| `ims-account-aurora-us-west-2-cluster-2` | reader               | **writer** |

Reader region us-east-1 has three secondary instances (`cluster-0/1/2`), but the metrics show they were quiet during the incident window (traffic did not shift east).

---

## Metric summary — writer at incident time (cluster-0)

Window: 2026-09-11 22:00 UTC → 2026-09-12 01:00 UTC, 1-minute granularity.

| Metric                            | Peak            | Average         | Notes                                                                 |
|-----------------------------------|-----------------|-----------------|-----------------------------------------------------------------------|
| CPUUtilization (%)                | **99.85**       | 72.52           | Sustained saturation across most of the window                        |
| DatabaseConnections               | **4,504**       | 2,900           | Connection storm — likely at or above `max_connections`               |
| CommitLatency (ms)                | **57.17**       | 4.00            | ~57× baseline; indicative of contention or IO stall                   |
| CommitThroughput (commits/s)      | 7,870           | 5,492           | High write pressure                                                   |
| WriteIOPS                         | 3,093           | 704             | Elevated write load                                                   |
| WriteThroughput (bytes/s)         | 798,877         | 158,370         | Elevated                                                              |
| DiskQueueDepth                    | **9**           | 0.66            | Non-zero queue depth indicates IO contention                          |
| NetworkReceiveThroughput          | 3,436,858       | 2,445,486       | Significant client-side traffic                                       |
| NetworkTransmitThroughput         | 5,389,050       | 3,732,956       | Significant response traffic                                          |
| FreeableMemory (bytes)            | 74,657,640,448  | 62,923,390,118  | ~74 GB peak → ~63 GB avg (some memory pressure, no swap)              |
| SwapUsage                         | 0               | 0               | No swap — memory was tight but not exhausted                          |
| BufferCacheHitRatio (%)           | 100.00          | 99.15           | Cache still hot; not an IO cache-miss problem                         |
| ReadIOPS                          | 0.02            | 0.00            | Zero physical reads (working set fully in cache)                      |
| DBLoad / DBLoadCPU / DBLoadNonCPU | **N/A**         | **N/A**         | **Performance Insights was disabled — no DBLoad datapoints**          |

**Interpretation:** this was a **write-heavy CPU-bound** incident, not IO-bound in the traditional sense (buffer cache 100%, ReadIOPS zero). The commit latency spike + DiskQueueDepth of 9 point at contention on the WAL / commit path under very high concurrency. Without PI or logs we cannot say whether it was one runaway query, a connection pool bug (surge of short transactions), or a schema-level lock storm.

## Metric summary — reader that became new writer (cluster-2)

| Metric                  | Peak     | Average |
|-------------------------|----------|---------|
| CPUUtilization (%)      | 15.32    | 2.48    |
| DatabaseConnections     | 1,819    | 249     |
| CommitLatency (ms)      | 0.09     | 0.02    |
| CommitThroughput        | 1,737    | 178     |
| ReadIOPS                | 28       | 0.93    |
| BufferCacheHitRatio (%) | 100.00   | 99.17   |

Absorbed some read traffic but was healthy throughout — sensible failover target.

## Metric summary — other reader (cluster-1)

| Metric              | Peak | Average |
|---------------------|------|---------|
| CPUUtilization (%)  | 0.88 | 0.59    |
| DatabaseConnections | 17   | 17      |

Essentially idle. Suggests reader endpoint routing is not evenly balanced or this instance is not in the reader pool for the workload.

---

## Failover analysis

Confirmed events from `rds-events/cluster-us-west-2.json` and per-instance event files:

```
2026-09-12 00:14:55.811Z  cluster       failover      Started cross AZ failover to DB instance: ims-account-aurora-us-west-2-cluster-2
2026-09-12 00:14:57.781Z  cluster-2                   Parameter max_wal_senders was set to a value incompatible with replication. It has been adjusted from 10 to 20.
2026-09-12 00:15:06.683Z  cluster-2     availability  DB instance restarted
2026-09-12 00:15:10.199Z  cluster-0                   A new writer was promoted. Restarting database as a reader.
2026-09-12 00:15:16.011Z  cluster       failover      Completed RDS initiated failover to DB instance: ims-account-aurora-us-west-2-cluster-2
2026-09-12 00:15:18.966Z  cluster-0     availability  DB instance restarted
```

**Key observations:**

- **RDS initiated the failover** — this is Aurora's built-in health monitor deciding the primary is unhealthy. It is not the same as a manual failover and not the same as customer/operator action. CloudTrail confirms no `FailoverDBCluster` API call was made by anyone in this account.
- **Total customer-visible failover downtime: ~21 seconds** (00:14:55 → 00:15:16). Aurora failover is fast; the ~5-minute application recovery gap (00:15:16 → 00:20) is app-side reconnect/retry behavior.
- **`max_wal_senders` parameter bug:** the cluster parameter group has this at a value RDS considered incompatible during promotion (auto-corrected to 20). Since the cluster runs on the default parameter group, this is a **default value that Aurora itself doesn't accept on this instance class**. Worth investigating in a proper (non-default) parameter group.

---

## Slow query / heavy SQL analysis — NOT AVAILABLE

**Performance Insights is disabled on all three writer-region instances.**

Verified from `describe-ims-account-aurora-us-west-2-cluster-0.json`:

```json
{
  "PerformanceInsightsEnabled": false,
  "PerformanceInsightsKMSKeyId": null,
  "PerformanceInsightsRetentionPeriod": null,
  "DbiResourceId": "db-RUZ4OVVDJ2OFMUGEL3KQ6FSSAM",
  "DBInstanceStatus": "available"
}
```

Same for cluster-1 and cluster-2. No historical DBLoad, no top-SQL, no wait-event breakdown for the incident window.

## PostgreSQL log analysis — NOT AVAILABLE

Earliest retained log file: `error/postgresql.log.2026-09-12-1800` (~20 hours after recovery). The 22:00–01:00 UTC incident-window files have rotated out. Default `rds.log_retention_period` on the parameter group is 4,320 minutes (3 days); today is ~4 days after the incident.

Cannot extract client IPs, slow queries, connection storms, errors, statement-timeout terminations, or lock waits from postgresql.log for this incident.

## Source service identification (IP → EC2 → tags) — NOT AVAILABLE

Depends on IPs from postgresql.log, which are gone. See "Configuration remediation" below.

## EventBridge findings

Scanned us-west-2 in account 889059331444:

- `eventbridge/rules-us-west-2.json` — general rules listing
- `eventbridge/scheduled-rules.json` — **empty**: no scheduled EventBridge rules
- `eventbridge/scheduler-list.json` — **empty**: no EventBridge Scheduler schedules

**No scheduled jobs in this account can be causally linked to the 22:38 UTC spike.** If a scheduled workload triggered it, it originated from a different account (application account / cross-account event bus target) or from the application layer (e.g. a cron on an EC2 / ECS scheduled task / K8s CronJob). This investigation cannot see those.

## Auto Scaling Group findings

None to correlate — we could not identify source EC2 instances (see IP mapping gap above). `asg/` directory contains discovery data for enumeration but nothing was tied back to a specific service.

## CloudTrail

`rds-events/cloudtrail-rds-us-west-2.json` was pulled (~200 KB). No manual RDS API calls (e.g. `FailoverDBCluster`, `RebootDBInstance`, `ModifyDBInstance`) recorded in the window — consistent with the RDS-initiated (not human-initiated) failover shown in RDS events.

---

## Methodology

- **Metrics:** 1-minute `AWS/RDS` metrics via `aws cloudwatch get-metric-statistics`, Average+Max+Min statistics, per instance and per cluster. Raw JSON per metric under `metrics/`, aggregated per-instance CSV also under `metrics/`.
- **Events:** `aws rds describe-events` with `--start-time` / `--end-time` (not `--duration`, which cannot be combined with explicit times), scoped to db-cluster and each db-instance.
- **Cluster + instance discovery:** `aws rds describe-global-clusters`, `describe-db-clusters`, `describe-db-instances` in both regions.
- **CloudTrail:** `aws cloudtrail lookup-events` filtered on `EventSource=rds.amazonaws.com`.
- **IP → service mapping (intended but not executed):** for each client IP found in postgresql.log, query `aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=<ip>`, then `describe-instances`, then read tags `Name`, `service`, `repo`, `environment`, `application`, `Team`, `AutoScalingGroupName`. Skipped because logs are gone.
- **All commands read-only.** No AWS resource was modified.

---

## Actionable next steps (prioritized)

### Priority 1 — Restore forensic capability (do this week)

These three changes are prerequisites for diagnosing any future incident. Without them the next incident is equally opaque.

1. **Enable Performance Insights on all three us-west-2 instances (and the us-east-1 secondaries).** Set retention to at least 7 days; 7 days is free. No downtime.

    ```pwsh
    $env:AWS_PROFILE = 'iam-account-prod-ikonawsadministratoraccess'
    foreach ($id in @(
        'ims-account-aurora-us-west-2-cluster-0',
        'ims-account-aurora-us-west-2-cluster-1',
        'ims-account-aurora-us-west-2-cluster-2'))
        {
            aws --region us-west-2 rds modify-db-instance `
                --db-instance-identifier $id `
                --enable-performance-insights `
                --performance-insights-retention-period 7 `
                --apply-immediately
        }  # end foreach (writer-region instances)
    ```

    Confirm with the Terraform module that owns this Aurora cluster — the change needs to be codified so it doesn't drift on the next `terraform apply`.

2. **Move off the default cluster + instance parameter groups.** `default.aurora-postgresql16` cannot be modified. Create custom groups and set at minimum:

    | Parameter                         | Default | Recommended                     | Why                                                                            |
    |-----------------------------------|---------|---------------------------------|--------------------------------------------------------------------------------|
    | `rds.log_retention_period`        | 4320    | 10080 (7 days) or higher        | Retain postgresql.log across weekend + business-hour report window             |
    | `log_min_duration_statement`      | -1      | 1000 (ms)                       | Capture queries slower than 1s to postgresql.log                               |
    | `log_connections`                 | 0       | 1                               | Capture per-connection client IP + user + database                             |
    | `log_disconnections`              | 0       | 1                               | Capture session duration on disconnect                                         |
    | `log_lock_waits`                  | 0       | 1                               | Capture waits exceeding `deadlock_timeout`                                     |
    | `log_temp_files`                  | -1      | 0                               | Log all temp files (helps identify work_mem-blowing queries)                   |
    | `log_autovacuum_min_duration`     | -1      | 1000                            | See long autovacuum runs                                                       |
    | `log_line_prefix`                 | Aurora  | `'%t [%p]: %r %u@%d [xid=%x] '` | Ensure `%r` (client host+port) is present for IP mapping                       |
    | `pg_stat_statements.track`        | top     | top                             | Confirm; also verify `shared_preload_libraries` contains `pg_stat_statements`  |

3. **Enable Aurora Postgres log export to CloudWatch Logs.** This gives indefinite retention and searchable log data independent of `rds.log_retention_period`.

    ```pwsh
    aws --region us-west-2 rds modify-db-cluster `
        --db-cluster-identifier ims-account-aurora-us-west-2-cluster `
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql"]}' `
        --apply-immediately
    ```

### Priority 2 — Investigate the `max_wal_senders` config bug

RDS auto-corrected `max_wal_senders` from 10 → 20 on cluster-2 during promotion. Once you've moved to a custom parameter group (Priority 1 #2), explicitly set `max_wal_senders` to a value appropriate for the number of readers + logical replication slots + any DMS / logical decoding. For a 3-node cluster with Aurora Global replication, 20 is a safe starting value.

### Priority 3 — Proactive alerting (do next sprint)

Current alerting only caught the incident after the on-call was paged by (presumably) high-level app symptoms. Add CloudWatch alarms directly on the DB:

| Metric                     | Threshold                 | Comparison           | Period | Consecutive breaches |
|----------------------------|---------------------------|----------------------|--------|----------------------|
| CPUUtilization             | 85 %                      | GreaterThanThreshold | 60 s   | 3                    |
| DatabaseConnections        | 80 % of `max_connections` | GreaterThanThreshold | 60 s   | 3                    |
| CommitLatency              | 10 ms                     | GreaterThanThreshold | 60 s   | 5                    |
| DiskQueueDepth             | 1                         | GreaterThanThreshold | 60 s   | 5                    |
| FreeableMemory             | 10 % of instance memory   | LessThanThreshold    | 60 s   | 3                    |
| AuroraReplicaLagMaximum    | 30,000 ms                 | GreaterThanThreshold | 60 s   | 3                    |
| MaximumUsedTransactionIDs  | 1,000,000,000             | GreaterThanThreshold | 5 m    | 1                    |
| DBLoad (once PI is on)     | 2× vCPU count             | GreaterThanThreshold | 60 s   | 3                    |

The 22:38 UTC spike would have alerted 22:40–22:43 UTC (17–20 minutes earlier than the first human page at 23:00) on the CPU + connection alarms.

### Priority 4 — Application-side follow-up

Independent of the DB config, ask Content Services and any other app team connected to this cluster:

1. Do apps use PgBouncer (transaction-pooling) or connect direct? 4,504 connections is a smell — either `max_connections` is huge or there's no connection pooling.
2. Are apps configured with a statement timeout? If not, one runaway query pinned an entire connection pool. Recommend `statement_timeout = 60000` (60s) at the role level as a safety net.
3. Is there a scheduled batch job (application-side cron, K8s CronJob, Argo Workflow, ECS scheduled task) that runs at 16:38 MDT (22:38 UTC) on Fridays? EventBridge scans in this account came up empty, so the scheduler is elsewhere.

### Priority 5 — Longer-term

- Codify all of Priority 1 in Terraform (the module that provisioned this Aurora cluster). A one-off `modify-db-*` will drift on the next apply.
- Consider `pg_stat_statements` snapshot capture on a schedule (e.g. every 5 min, dumped to a small metadata DB or S3) so post-mortems can compare against baseline even if PI/logs are gone.

---

## Appendix A — Key file inventory

| File                                                             | Purpose                                                                  |
|------------------------------------------------------------------|--------------------------------------------------------------------------|
| `report.md`                                                      | This document                                                            |
| `report.subagent.md`                                             | Original subagent-generated report (kept for reference)                  |
| `cluster-writer-config.json`                                     | `describe-db-clusters` output for us-west-2 primary                      |
| `reader-cluster-config.json`                                     | `describe-db-clusters` output for us-east-1 secondary                    |
| `describe-ims-account-aurora-us-west-2-cluster-{0,1,2}.json`     | Per-instance describe (shows PI = disabled)                              |
| `metrics/*.json`                                                 | Raw per-metric CloudWatch responses                                      |
| `metrics/ims-account-aurora-us-west-2-cluster-{0,1,2}.csv`       | Per-instance aggregated 1-min metrics as CSV                             |
| `rds-events/cluster-us-west-2.json`                              | Cluster-level RDS events (contains failover events)                      |
| `rds-events/ims-account-aurora-us-west-2-cluster-{0,1,2}.json`   | Per-instance RDS events (contains restart events during promotion)       |
| `rds-events/cloudtrail-rds-us-west-2.json`                       | CloudTrail lookup for RDS API calls in window                            |
| `logs/log-file-list-ims-account-aurora-us-west-2-cluster-*.json` | `describe-db-log-files` per instance (proves incident-window files gone) |
| `eventbridge/scheduled-rules.json`                               | Empty — no scheduled EventBridge rules in this account+region            |
| `eventbridge/scheduler-list.json`                                | Empty — no EventBridge Scheduler schedules                               |
| `api-errors.log`                                                 | AWS API error transcript from initial subagent run                       |

## Appendix B — What we intentionally did NOT do

- No RDS modification, reboot, failover, parameter change (all read-only investigation)
- No modification of application/EC2/ASG resources
- No queries executed against the database itself — findings are entirely from AWS control-plane data
- No cross-account CloudTrail search (only account 889059331444 was scanned)

---

## Addendum — RDS Proxy investigation (2026-09-15)

Answer to "did the RDS Proxy have connection issues?" — **YES, unambiguously.** The proxy was pool-saturated and hitting its `ConnectionBorrowTimeout` for most of the incident. It is also being bypassed by most application traffic, which is what actually killed the writer.

### Proxy identified

| Field                        | Value                                                                      |
|------------------------------|----------------------------------------------------------------------------|
| `DBProxyName`                | `account-db-prod-proxy-us-west-2`                                          |
| `Endpoint`                   | `account-db-prod-proxy-us-west-2.proxy-c38c4oymc9wd.us-west-2.rds.amazonaws.com` |
| `EngineFamily`               | `POSTGRESQL`                                                               |
| `TrackedClusterId`           | `ims-account-aurora-us-west-2-cluster` (the incident cluster)              |
| `MaxConnectionsPercent`      | **90 %**                                                                   |
| `MaxIdleConnectionsPercent`  | 75 %                                                                       |
| `ConnectionBorrowTimeout`    | **5 seconds**                                                              |
| `SessionPinningFilters`      | (none)                                                                     |
| `MaxDatabaseConnectionsAllowed` (observed) | **261**                                                      |

`MaxDatabaseConnectionsAllowed = MaxConnectionsPercent × cluster max_connections`. 261 / 0.90 ≈ **290** — the underlying instance `max_connections` is only ~290, which is the Aurora default and is dramatically undersized for a workload that ran ~4,500 concurrent sessions.

### Proxy metric summary (window 22:00 UTC → 01:00 UTC, 1-min)

Raw JSON: `rds-proxy/metrics/*.json` · CSV: `rds-proxy/proxy-metrics-1min.csv` · Summary: `rds-proxy/proxy-metrics-summary.md`

| Metric                                    | Unit  | Peak       | Avg       | Notes                                                    |
|-------------------------------------------|-------|------------|-----------|----------------------------------------------------------|
| ClientConnections                         | count | **908**    | 158       | Active client sessions on proxy (~60× pre-spike)         |
| ClientConnectionsReceived                 | /min  | **3,417**  | 156       | Client reconnect storm                                   |
| ClientConnectionsClosed                   | /min  | **3,438**  | 144       | Matches Received → connect/close churn                   |
| ClientConnectionsSetupSucceeded           | /min  | 3,370      | 155       | Almost all setups completed                              |
| ClientConnectionsSetupFailedAuth          | count | *no data*  | *no data* | Not published → 0 auth failures in window                |
| DatabaseConnections                       | count | **261**    | 52        | Pinned at proxy ceiling for hours                        |
| DatabaseConnectionsCurrentlyBorrowed      | count | 261        | 22        | All 261 in-use for extended periods                      |
| DatabaseConnectionsCurrentlySessionPinned | count | *no data*  | *no data* | 0 pinning — pool is functioning as designed              |
| DatabaseConnectionsBorrowLatency          | μs    | **7,131,550 (7.13 s)** | 367,586 (368 ms) | Above the 5 s `ConnectionBorrowTimeout` ceiling |
| DatabaseConnectionRequests                | /min  | 1,479      | 285       | Client requests for a pool connection                    |
| MaxDatabaseConnectionsAllowed             | count | 261        | 261       | Static during window                                     |
| QueryDatabaseResponseLatency              | μs    | 16,379,784 (**16.4 s**) | 3,255,794 (3.26 s) | Sparse (3 samples) — queries were also slow  |
| QueryRequests                             | /min  | 215        | 54        | Sparse                                                   |

### Timeline — proxy behavior mapped to incident

| UTC   | ClientConns | DBConns (of 261) | BorrowLatency avg / max | Interpretation                                                     |
|-------|-------------|------------------|-------------------------|--------------------------------------------------------------------|
| 22:35 | 15 / 28     | 32 / 117 max     | 99 μs / 1.4 ms          | Normal.                                                            |
| 22:38 | 16 / 28     | 32 / 117         | 96 μs / 0.9 ms          | Aurora writer CPU spike started but proxy still calm.              |
| 23:00 | 136 / 142   | 87 / **261**     | **239 ms** / **1.15 s** | Pool hit ceiling. Borrow latency jumped 3 orders of magnitude.     |
| 23:30 | 96 / 103    | 87 / 261         | 109 ms / 747 ms         | Still queueing hard.                                               |
| 00:10 | 274 / 465   | 55 / 261         | **3.04 s** / **5.37 s** | **Above 5 s ConnectionBorrowTimeout** → clients getting errors.    |
| 00:14 | 302 / 449   | 37 / 261         | **3.10 s** / **5.28 s** | Same. Content Services already disconnected — this is retry storm. |
| 00:15 | 125 / 155   | 35 / 149         | 641 ms / 4.92 s         | Failover completed → borrow queue draining.                        |
| 00:20 | 92 / 114    | 35 / 149         | 78 μs / 2 ms            | Recovered to baseline.                                             |

Peak 7.13 s borrow latency, sustained multi-second averages, and `DatabaseConnections` pinned at 261 = the proxy's `ConnectionBorrowTimeout` of 5 s was firing continuously. Every one of those timeouts is an application-visible error (typically surfaces as `error: timed out waiting to acquire a database connection`).

### The bigger issue — the proxy is being bypassed

The proxy only ever opened **261** DB connections at peak. But the writer instance saw **4,504** concurrent sessions. That leaves **~4,243 direct-to-cluster connections** that bypassed the proxy entirely and hit the Aurora cluster/instance endpoints.

Those direct connections filled `max_connections` and drove CPU to 99.8 %. The proxy could not protect the DB because most apps aren't going through it. The apps that *are* using the proxy suffered — 5-second borrow timeouts and connection storms — but they didn't cause the primary damage.

### What the proxy metrics do *not* show

- **No auth failures** (`ClientConnectionsSetupFailedAuth` was not published → CloudWatch behavior for zero-value proxy metrics is to omit the datapoint).
- **No session pinning** (`DatabaseConnectionsCurrentlySessionPinned` also no data → zero). The pool was multiplexing correctly; the problem was pure pool exhaustion, not pinning breaking transaction pooling.
- **No target-level metrics per instance** — proxy metrics with `Target` dimension are sparse for TRACKED_CLUSTER + per-instance targets. Not pulled.

### New action items (in addition to Priority 1–5 above)

**Priority 1a — Force applications through the proxy** (highest impact — this is what would have prevented the incident):

- Identify every service currently connecting to `ims-account-aurora-us-west-2-cluster.cluster-c38c4oymc9wd.us-west-2.rds.amazonaws.com` (writer endpoint) or `.cluster-ro-c38c4oymc9wd...` (reader endpoint).
- Repoint them at `account-db-prod-proxy-us-west-2.proxy-c38c4oymc9wd.us-west-2.rds.amazonaws.com`.
- Enforce with a **security group rule change**: the proxy's SG (`sg-0c01aa6afc4213e65`) is allowed onto the Aurora cluster's SG on 5432, but application SGs should be removed. Only the proxy SG can reach the DB. This is the only durable way to prevent bypass — code-level "use the proxy endpoint" conventions drift.

**Priority 1b — Raise the DB `max_connections`:**

- With ~290 today, the pool ceiling is 261 (90 %). If apps are correctly funneled through the proxy, 261 is likely still too low for the observed workload.
- On a custom cluster parameter group set `max_connections` explicitly. Aurora r6g.2xlarge and up can safely support 2,000–5,000 with adequate `work_mem`/`shared_buffers` tuning. Recommend starting at **2,000**, giving `MaxConnectionsPercent × 2000 = 1,800` proxy pool.
- Sanity-check with the writer instance class — the default formula `LEAST({DBInstanceClassMemory/9531392}, 5000)` is what produced ~290, so the instance is likely small. Consider a size-up in the same change window.

**Priority 1c — Raise `ConnectionBorrowTimeout` OR tune it deliberately:**

- Current 5 s = every second the DB is slow, borrow requests > 5 s become client errors.
- If we *want* fail-fast (Priority 1a done, DB right-sized), keep 5 s.
- If we want to absorb short DB blips, raise to 15–30 s. Trade-off: slow queries pile up client-side.

**Priority 1d — Add proxy-level CloudWatch alarms** (in addition to the DB-side alarms in Priority 3):

| Metric                                | Threshold                         | Comparison           | Period | Consecutive |
|---------------------------------------|-----------------------------------|----------------------|--------|-------------|
| DatabaseConnectionsBorrowLatency      | 100,000 (100 ms)                  | GreaterThanThreshold | 60 s   | 3           |
| DatabaseConnections / MaxDBConnAllowed | 80 % (use math expression)       | GreaterThanThreshold | 60 s   | 3           |
| ClientConnectionsSetupFailedAuth      | 0                                 | GreaterThanThreshold | 60 s   | 1           |
| DatabaseConnectionsCurrentlySessionPinned | 0                              | GreaterThanThreshold | 60 s   | 5           |

The `DatabaseConnectionsBorrowLatency` alarm would have fired at 22:55 UTC — **5 minutes ahead of the first human page** and 1 h 20 m ahead of the failover.

### Proxy files added

| File                                       | Purpose                                            |
|--------------------------------------------|----------------------------------------------------|
| `rds-proxy/proxy-describe.json`            | Full `describe-db-proxies` output                  |
| `rds-proxy/proxy-target-groups.json`       | Target group config (pool sizing, borrow timeout)  |
| `rds-proxy/proxy-targets.json`             | Registered targets (all 3 us-west-2 instances)     |
| `rds-proxy/proxy-endpoints.json`           | Additional proxy endpoints (none custom)           |
| `rds-proxy/pull-proxy-metrics.sh`          | CloudWatch pull script (reproducible)              |
| `rds-proxy/metrics/*.json`                 | Raw per-metric CloudWatch responses                |
| `rds-proxy/proxy-metrics-1min.csv`         | Aggregated 1-min proxy metrics as CSV              |
| `rds-proxy/proxy-metrics-summary.md`       | Peak/avg + per-anchor snapshot summary             |
| `rds-proxy/summarize.py`                   | Summary builder                                    |
