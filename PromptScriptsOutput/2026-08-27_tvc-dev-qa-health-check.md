# TVC Aurora PostgreSQL Health Check — `tvc-development-cluster` & `tvc-qa-cluster`

- **AWS Account:** Inscape Production US 1 (`788724168120`)
- **Region:** us-east-1
- **Clusters investigated:**
  - `arn:aws:rds:us-east-1:788724168120:cluster:tvc-development-cluster` — endpoint `tvc-development-cluster.cluster-cujpo2r0mujo.us-east-1.rds.amazonaws.com`
  - `arn:aws:rds:us-east-1:788724168120:cluster:tvc-qa-cluster` — endpoint `tvc-qa-cluster.cluster-cujpo2r0mujo.us-east-1.rds.amazonaws.com`
- **Engine:** Aurora PostgreSQL 17.7 (single-instance writer, no reader in either cluster)
- **Window analyzed:** 2026-08-27 11:16 UTC → 16:16 UTC (last 5 hours)
- **Reported issue:** performance degradation / connection issues
- **Data sources used:** CloudWatch (`AWS/RDS`, 1-minute granularity), RDS Events API, Performance Insights (`db.load.avg`)

## Executive summary

**Verdict: No performance degradation detected on either cluster in the analyzed window.**

- **`tvc-development`**: CPU averaged 9.8% (max 13.5%), connections stable at ~32, memory flat at ~3.36 GB free, read/write latency ~0 ms, buffer cache hit ratio 100%, DB load averaged 0.001 active sessions. Zero RDS events.
- **`tvc-qa`**: CPU averaged 10.0% (max 13.3%), connections stable at ~70, memory flat at ~3.21 GB free, read/write latency ~0 ms, buffer cache hit ratio 100%. Zero RDS events. (Performance Insights DB load could not be queried — see gap below.)
- No slow-query, connection-storm, or IO-contention signal was present in either cluster, so the deeper source-IP / EC2 / EventBridge / Auto Scaling Group tracing steps were not required and were not run.
- One gap: Performance Insights `db.load.avg` for `tvc-qa` returned `NotAuthorizedException` under the current IAM role — see Action Items.

## Metric summary — `tvc-development` (member of `tvc-development-cluster`)

| Metric                         |           Min |           Avg |           Max |          Last | Notes                               |
|--------------------------------|--------------:|--------------:|--------------:|--------------:|-------------------------------------|
| CPUUtilization (%)             |          8.77 |          9.76 |         13.53 |          9.89 | Flat, low                           |
| DatabaseConnections            |            31 |         32.39 |            37 |            36 | Stable                              |
| FreeableMemory (bytes)         | 3,329,638,400 | 3,362,063,688 | 3,374,743,552 | 3,341,254,656 | Flat, no downward/leak trend        |
| ReadIOPS                       |          0.00 |          0.00 |          0.02 |          0.00 | Effectively idle reads              |
| WriteIOPS                      |         10.71 |         11.02 |         13.02 |         11.07 | Steady baseline writes              |
| ReadLatency (s)                |         0.000 |         0.000 |         0.001 |         0.000 | Negligible                          |
| WriteLatency (s)               |         0.000 |         0.000 |         0.000 |         0.000 | Negligible                          |
| NetworkReceiveThroughput (B/s) |         21.26 |        105.53 |      4,106.73 |         46.16 | Small bursts, no sustained pressure |
| BufferCacheHitRatio (%)        |        99.997 |       100.000 |       100.000 |       100.000 | No buffer-pool pressure             |
| AuroraReplicaLag               |           n/a |           n/a |           n/a |           n/a | No reader instance in this cluster  |
| PI db.load.avg (AAS)           |            -- |         0.001 |         0.007 |            -- | Virtually no active sessions        |

- **RDS Events (5h window):** none

## Metric summary — `tvc-qa` (member of `tvc-qa-cluster`)

| Metric                         |           Min |           Avg |           Max |          Last | Notes                                                               |
|--------------------------------|--------------:|--------------:|--------------:|--------------:|---------------------------------------------------------------------|
| CPUUtilization (%)             |          8.87 |          9.96 |         13.33 |          9.62 | Flat, low                                                           |
| DatabaseConnections            |            68 |         70.14 |            74 |            73 | Stable                                                              |
| FreeableMemory (bytes)         | 3,189,829,632 | 3,212,534,265 | 3,224,879,104 | 3,197,755,392 | Flat, no downward/leak trend                                        |
| ReadIOPS                       |          0.00 |          0.00 |          0.00 |          0.00 | Effectively idle reads                                              |
| WriteIOPS                      |          6.37 |         11.03 |         15.50 |         11.09 | Steady baseline writes                                              |
| ReadLatency (s)                |         0.000 |         0.000 |         0.000 |         0.000 | Negligible                                                          |
| WriteLatency (s)               |         0.000 |         0.000 |         0.001 |         0.000 | Negligible                                                          |
| NetworkReceiveThroughput (B/s) |          7.40 |         58.11 |        674.61 |         31.21 | Small bursts, no sustained pressure                                 |
| BufferCacheHitRatio (%)        |       100.000 |       100.000 |       100.000 |       100.000 | No buffer-pool pressure                                             |
| AuroraReplicaLag               |           n/a |           n/a |           n/a |           n/a | No reader instance in this cluster                                  |
| PI db.load.avg (AAS)           |           n/a |           n/a |           n/a |           n/a | NotAuthorizedException for this DbiResourceId under Inscape-AWS-Ops |

- **RDS Events (5h window):** none

## Memory trend vs. prior same-weekdays

Not run this pass — FreeableMemory for both instances was flat and near its ceiling for the full 5-hour window analyzed, with no anomaly to compare against a baseline. If a memory anomaly is later observed, re-run this comparison for the two prior Thursdays (2026-08-20, 2026-08-13) at the same UTC window.

## Temp tables written to disk

Not assessed — this requires either Performance Insights counter metrics for `Created_tmp_disk_tables` or a direct read-only `SHOW GLOBAL STATUS` query, neither of which was run since there is no CPU/IO/latency signal suggesting temp-table spill in this window. Not prioritized given the clean metrics above.

## Queries consuming large memory / causing IO contention

None found. `db.load.avg` for `tvc-development` averaged 0.001 active sessions (max 0.007) over the window — there is no concurrent query load to attribute IO contention to. `ReadIOPS`/`ReadLatency`/`WriteLatency` are at or near zero for both instances. No top-SQL analysis was run because there was no load to analyze.

## Slow query log analysis

Not run. Both clusters show zero read latency and near-zero DB load, so there is no indication of slow-running queries in this window. Source-IP extraction from slow query logs, `describe-network-interfaces`/`describe-instances` tracing, EventBridge rule checks, and Auto Scaling Group review were skipped for the same reason — there was nothing to trace back to a source service.

## Source service identification table

Not applicable — no slow queries or connection spikes were identified in this window to trace back to source IPs/services.

## Methodology

1. Confirmed AWS identity/account via `aws sts get-caller-identity` (account `788724168120`, role `Inscape-AWS-Ops`).
2. Resolved both cluster ARNs to their member DB instances via `aws rds describe-db-clusters` (`tvc-development-cluster` → `tvc-development`; `tvc-qa-cluster` → `tvc-qa`), confirming Aurora PostgreSQL 17.7, single-instance (writer-only, no reader).
3. Pulled 1-minute `AWS/RDS` CloudWatch metrics for the 5-hour window via batched `aws cloudwatch get-metric-data` calls per instance: `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReadIOPS`, `WriteIOPS`, `ReadLatency`, `WriteLatency`, `NetworkReceiveThroughput`, `AuroraReplicaLag`, `BufferCacheHitRatio`.
4. Queried `aws rds describe-events` for both clusters (source-type `db-cluster`) over the same window — zero events returned for either.
5. Queried Performance Insights (`aws pi get-resource-metrics`, metric `db.load.avg`, 5-minute period) for each instance's `DbiResourceId` to check average active sessions; succeeded for `tvc-development`, failed with `NotAuthorizedException` for `tvc-qa`'s resource under the current role.
6. Did not proceed to slow-query-log extraction, EC2/ENI tracing, EventBridge, or Auto Scaling Group checks, since no metric or event indicated degradation to investigate further.

## Timeline

| Time (UTC)    | Observation                                                                                                                                                                                        |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 11:16 - 16:16 | Both clusters steady: CPU ~9-10%, connections stable (32 avg dev / 70 avg qa), memory flat, IO latency ~0, buffer cache hit 100%, zero RDS events. No anomaly detected at any point in the window. |

## Action items

None required based on this data. Optional follow-ups if the reported symptom recurs or is time-boxed to a specific moment not covered here:

1. **Re-run for the exact reported incident time.** If the "performance degradation / connection issues" was observed at a specific timestamp outside 11:16–16:16 UTC today, re-run this same pull for that exact window.
2. **Fix Performance Insights access for `tvc-qa`.** The `Inscape-AWS-Ops` role got `NotAuthorizedException` calling `pi:GetResourceMetrics` for `tvc-qa`'s `DbiResourceId` — worth a quick IAM check (`aws pi list-tags-for-resource` / policy review) so PI data is available for both instances going forward.
3. **If connection issues persist**, check application-side connection pool exhaustion/timeouts and security-group/network-path changes, since `DatabaseConnections` on the DB side was stable and did not spike.
4. **Confirm reported symptom source.** Since CloudWatch, PI, and RDS Events all show a clean bill of health, consider whether the reported issue originated from a different resource (e.g., an app-tier timeout, DNS resolution issue, or a different database instance) rather than these two clusters.
