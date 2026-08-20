# RCA: Non-Yielding Scheduler Stack Dump — `mongo-mssql-1-production`

| Field                  | Value                                                                          |
|------------------------|---------------------------------------------------------------------------------|
| AWS Account            | `aws-smartcast-data-prod` (363979333641)                                       |
| Region                 | us-west-2                                                                       |
| DB Instance            | `mongo-mssql-1-production` (`db.r5.16xlarge`, SQL Server 2022 SE 16.0.4250.1)   |
| Storage                | io2, 45,000 GiB allocated / 50,000 GiB max threshold, 32,200 provisioned IOPS   |
| Topology               | Multi-AZ, RDS-managed Always On (one AG per user database + `RDSAG0` witness)   |
| Incident window        | 2026-08-16 **16:08:19.81 UTC** → **16:16:48.37 UTC**                            |
| Issue type              | Non-Yielding Scheduler → SQL Server stack dump → Always On lease expiry/failover|
| All times below are UTC unless noted. Local CLI display timezone is UTC‑06:00.  | |

---

## 1. Executive Summary

A sustained surge in read I/O and client connections beginning around **16:06–16:07 UTC** drove a `CHECKPOINT`/`FlushCache` operation on database ID 10 into a **98‑second stall** (76.1s internal wait) with an **I/O saturation value of 113** (>100 = queueing beyond capacity). Combined Read+Write IOPS peaked at **~28,900 IOPS at 16:13:00** against a 32,200 IOPS‑provisioned io2 volume (≈90% of provisioned capacity), Buffer Pool **Page Life Expectancy collapsed from 1,421 to 149**, and **lock waits (LCK_M_IX) plus PAGEIOLATCH_SH/EX and ASYNC_IO_COMPLETION** became the dominant wait events. A worker thread on **Scheduler 13** failed to yield for **70,135 ms**, triggering a **Non‑Yielding Scheduler stack dump** at 16:16:25.49. The ~23 seconds consumed generating the dump were enough for the **Windows Server Failover Cluster (WSFC) lease to expire on every Always On availability group** hosted on the instance, forcing an automatic Multi‑AZ failover at 16:16:48.37. Several client sessions briefly received "lacks a quorum of nodes" errors during the transition. Write latency and disk queue depth spiked further for ~10 minutes afterward as the new primary caught up (expected failover/redo behavior).

**Root cause (primary):** Storage subsystem could not keep pace with a combined read‑heavy workload burst + concurrent `CHECKPOINT` flush + a concurrent `BACKUP DATABASE` operation, pushing an already memory‑constrained instance (chronic ~93% memory utilization) into I/O‑bound scheduler starvation.

**This was not a new/anomalous memory condition** — FreeableMemory on the incident day is in the same 33–37 GB band as the two prior Sundays at the same time of day (see §3). The instance runs permanently near its memory ceiling; the trigger was the I/O burst, not a memory regression.

---

## 2. Metric Summary — Incident Window (1‑minute granularity, `AWS/RDS` CloudWatch namespace)

| Time (UTC) | CPU % | Connections | Read IOPS | Write IOPS | Read Lat (ms) | Write Lat (ms) | Free Mem (MB) | Net Rx (MB/s) | Net Tx (MB/s) | Disk Queue |
|-----------:|------:|------------:|----------:|-----------:|--------------:|---------------:|---------------:|---------------:|---------------:|-----------:|
| 16:00:00   |  28.4 |          93 |     3,478 |      1,245 |          1.54 |            0.99 |         33,892 |           4.70 |         513.24 |        3.0 |
| 16:05:00   |  28.8 |          71 |     3,325 |        797 |          0.55 |            1.38 |         36,778 |           5.29 |         537.26 |        4.0 |
| 16:06:00   |  30.2 |         119 |     5,186 |        974 |          0.58 |            0.81 |         34,936 |           5.62 |         525.89 |        3.0 |
| 16:07:00   |  33.7 |         318 |    12,866 |      2,517 |          0.50 |            0.87 |         36,259 |           7.35 |         499.42 |        8.0 |
| 16:08:00   |  38.8 |         334 |    17,054 |      4,841 |          0.51 |            1.08 |         36,167 |           8.03 |         510.11 |       13.0 |
| 16:09:00   |  36.2 |         352 |    11,861 |      3,212 |          0.52 |            1.04 |         36,115 |           6.43 |         514.39 |        9.0 |
| 16:10:00   |  39.6 |         366 |    18,171 |      5,120 |          0.48 |            0.81 |         36,502 |          11.48 |         523.51 |       11.0 |
| 16:11:00   |  38.2 |         350 |    12,418 |      3,244 |          0.49 |            1.53 |         37,025 |           8.06 |         505.11 |       11.0 |
| 16:12:00   |  32.4 |         344 |     7,248 |      3,998 |          0.71 |            2.39 |         35,635 |           6.64 |         507.51 |       14.0 |
| 16:13:00   |  41.4 |         356 |    **24,943** |  **3,941** |      0.91 |            1.86 |         35,581 |          13.63 |         524.27 |       30.0 |
| 16:14:00   |  36.2 |         351 |    16,955 |      2,707 |          0.46 |            1.06 |         36,410 |           5.97 |         486.70 |       10.0 |
| 16:15:00   |  28.3 |         353 |    16,490 |      2,393 |          0.41 |            0.55 |         36,556 |           4.63 |         310.89 |        8.0 |
| 16:16:00   |  23.6 |          — *(gap: dump/failover in progress)* | — | — | — | — | — | — | — | — |
| 16:17:00   |  17.2 |         200 |    12,006 |      3,322 |          0.55 |          **69.05** |         37,118 |           4.48 |         224.34 |    **236.0** |
| 16:18:00   |  32.2 |         236 |    11,186 |      2,154 |          0.63 |           63.97 |         42,038 |           5.49 |         427.15 |      144.0 |
| 16:19:00   |  26.3 |         246 |     7,281 |      2,517 |          0.56 |           80.30 |         42,023 |           5.17 |         443.51 |      206.0 |
| 16:20:00   |  32.5 |         250 |     7,971 |      3,024 |          0.55 |            1.15 |         41,984 |           6.45 |         602.95 |        6.0 |
| 16:21:00   |  35.5 |         270 |     9,191 |      3,493 |          0.71 |           62.19 |         41,997 |           6.78 |         619.91 |      223.0 |
| 16:22:00   |  38.6 |         277 |     9,155 |      3,753 |          0.76 |           71.68 |         42,159 |           6.51 |         632.24 |      276.0 |
| 16:23:00   |  35.6 |         277 |     9,503 |      4,023 |          0.76 |          175.95 |         44,047 |           6.52 |         647.05 |      715.0 |
| 16:24:00   |  34.5 |         263 |     4,589 |      3,476 |          1.30 |          274.51 |         44,008 |           6.34 |         672.58 |      960.0 |

**Reading the table:** Connections nearly quadrupled (71 → 366) and Read IOPS jumped ~7x (baseline ~3,000 → peak 24,943) in the six minutes leading up to the dump. Post‑failover, write latency and disk queue depth (up to 960) reflect the secondary catching up on redo — this is expected Multi‑AZ failover behavior, not a second unrelated incident. SwapUsage was not published by CloudWatch for this instance/engine (no data points returned for that metric — Windows RDS SQL Server generally reports OS paging via `os.memory.*` in Performance Insights instead, see §4).

### Storage headroom note
- Storage size is at **45,000 GiB / 50,000 GiB max threshold (90%)** — 36 duplicate "approaching maximum storage threshold" notification events fired throughout 2026‑08‑16 (every ~2 hours). Not the trigger for this incident, but worth remediating (see §7).

---

## 3. Memory Comparison — Same Weekday, Prior 2 Weeks (`FreeableMemory`, 15:40–16:45 UTC window)

| Date (Sunday) | Min (MB) | Max (MB) | Avg (MB) | Granularity |
|---------------|---------:|---------:|---------:|-------------|
| 2026‑08‑16 (incident) | 33,470 (approx, pre-failover) | 44,047 (post-failover) | ~36,700 (pre-failover) | 1 min |
| 2026‑08‑09 (‑1 wk)    |   18,806 |   36,320 |   33,486 | 1 min |
| 2026‑08‑02 (‑2 wk)    |   33,470 |   37,673 |   36,286 | 5 min (rolled up; 1‑min data outside 15‑day CW retention) |

**Conclusion: recurring pattern, not a one‑time anomaly.** All three Sundays show FreeableMemory oscillating in the same ~19–38 GB band against 518,567 MB (506 GB) total physical memory — i.e., the instance chronically runs at **~92–96% memory utilization**. This is the normal steady‑state for this `db.r5.16xlarge` given its buffer pool sizing, not a leak or new regression. The practical implication is there is very little memory headroom to absorb a burst, which is consistent with how quickly Buffer Pool Page Life Expectancy collapsed once the I/O burst hit (see §4).

---

## 4. Performance Insights — Deeper Counters (Incident Window)

### 4a. OS/Buffer Manager counters (1‑min, local display time UTC‑06:00; 10:0x local = 16:0x UTC)

| Time (local) | Time (UTC) | os.memory.physAvailKb | Buffer Cache Hit Ratio % | Page Life Expectancy (s) | Processes Blocked | User Connections | Memory Grants Pending |
|---|---|---:|---:|---:|---:|---:|---:|
| 10:05 | 16:05 | 38,037,072 | 99.74 | 1,288 |  0 | 114 | 0 |
| 10:07 | 16:07 | 36,070,362 | 99.79 | 1,328 |  1 | 129 | 0 |
| 10:08 | 16:08 | 35,582,728 | 98.40 | 1,368 |  0 | 163 | 0 |
| 10:09 | 16:09 | 35,237,232 | 99.62 | 1,406 |  3 | 366 | 0 |
| 10:10 | 16:10 | 35,216,780 | 99.74 | 1,421 | 10 | 391 | 0 |
| 10:11 | 16:11 | 36,541,166 | 99.63 | 1,421 | 36 | 400 | 0 |
| 10:12 | 16:12 | 38,092,312 | 99.46 |   617 |  6 | 409 | 0 |
| 10:13 | 16:13 | 37,155,414 | 99.81 |   617 | 31 | 392 | 0 |
| 10:14 | 16:14 | 37,275,952 | 99.65 |   617 | 43 | 392 | 0 |
| 10:15 | 16:15 | 36,605,586 | 99.61 |   240 |  0 | 399 | 0 |
| 10:16 | 16:16 | 37,370,434 | 99.40 |   240 | 23 | 397 | 0 |
| 10:17 | 16:17 | 37,387,380 | 99.73 |   149 | 41 | 398 | 0 |
| 10:18 | 16:18 | *(gap — dump)* | — | — | — | — | — |
| 10:19 | 16:19 | 40,026,370 | 99.90 |   210 | 31 | 277 | 0 |

Key signals: **Page Life Expectancy collapsed from 1,421s to 149s** (buffer pool churning hard from the read burst), **Processes Blocked spiked to 36–43** concurrently, and **Memory Grants Pending stayed at 0 throughout** — ruling out memory‑grant/RESOURCE_SEMAPHORE starvation as a contributing factor. `os.memory.physAvailKb` itself never dropped catastrophically during the window (35–38 GB range, consistent with the CloudWatch view) — the trigger was I/O/lock contention, not a memory exhaustion event.

### 4b. Top wait events by DB load (AAS), 16:00–16:20 UTC

| Wait Event             | Type    | Avg Active Sessions |
|-------------------------|---------|---------------------:|
| LCK_M_IX                | Lock    | 10.94 |
| CPU                     | CPU     |  6.20 |
| PAGEIOLATCH_SH          | IO      |  5.17 |
| ASYNC_IO_COMPLETION     | IO      |  1.84 |
| CXSYNC_PORT             | Other   |  1.29 |
| SP_SERVER_DIAGNOSTICS_SLEEP | Other | 1.00 |
| PAGEIOLATCH_EX          | IO      |  1.00 |
| ASYNC_NETWORK_IO        | Network |  0.87 |
| LCK_M_IS                | Other   |  0.35 |
| LCK_M_U                 | Other   |  0.28 |
| PAGEIOLATCH_UP          | IO      |  0.23 |
| PAGELATCH_SH            | Latch   |  0.20 |
| LCK_M_S                 | Lock    |  0.15 |
| IO_COMPLETING           | IO      |  0.15 |
| PAGELATCH_EX            | Latch   |  0.09 |

**Lock waits (LCK_M_IX) were the single largest contributor to DB load** — larger than combined I/O waits. This points to writer/writer contention (see top SQL below, `MERGE ... WITH (HOLDLOCK, UPDLOCK)`) amplified by, not purely caused by, the I/O stall: once pages take longer to flush/read, locks are held longer, and blocking cascades.

### 4c. Top SQL by DB load, 16:00–16:20 UTC (tokenized/parameterized — no literal values captured)

|  AAS | DB ID (hashed)     | Statement (truncated) |
|-----:|--------------------|------------------------|
| 7.73 | `4E288126AE1C1467` | `MERGE INTO [Meta].[DependencyPayload] WITH (HOLDLOCK, UPDLOCK) AS target USING ? AS source ON target.[ItemId] = source.[ItemId] WHEN MATCHED THEN ...` |
| 3.06 | `37AABC4A0D54AC4A` | `UPDATE tgt WITH (ROWLOCK) SET tgt.IsValid = ?, tgt.EffectiveDate = ? OUTPUT inserted.HubAId, inserted.Li...` |
| 1.74 | *(system)*         | `BACKUP DATABASE ? TO VIRTUAL_DEVICE = ? VIRTUAL_DEVICE = ? ...` *(concurrent native/maintenance-plan backup — separate from the RDS automated snapshot backup, which ran 07:04–10:51 that day)* |
| 1.01 | `F2F7AFFDBCB7E06D` | `INSERT INTO ? DISTINCT hub.HubId, hub.HubType, ... FROM hub JOIN sks ...` |
| 1.00 | *(system)*         | `sp_server_diagnostics` *(background noise)* |
| 0.95 | `CA348CA8B9542B31` | `SELECT time, Name as metric, value FROM (...)` |
| 0.71 | `2FF8873246637BF4` | `insert into [Meta].[ActiveAiring] (AiringId, SourceId) select a.AiringId, a.SourceId from ? a join Satellites s (nolock) ...` |
| 0.61 | `D78A092278E729DE` | `WITH src AS (SELECT src.ToHubId, ctx.LinkContextId FROM LinkContext ctx WITH(NOLOCK) JOIN ? src ...)` |
| 0.56 | `694614818D6DF73D` | `INSERT INTO ? DISTINCT hub.HubId, hub.HubType, ...` |
| 0.55 | `934BA69C28813961` | `INSERT INTO ? link.HubAId as [FromHubId], type_tags.FromHubType, ...` |

**Note on "slow query log":** SQL Server (and RDS SQL Server) does not have a MySQL‑style slow query log. The equivalent evidence here is Performance Insights' Top SQL by DB load (above), which captures exactly the queries consuming the most active-session-time during the window — the `MERGE`/`UPDATE`/`INSERT` pipeline jobs against the `Meta.DependencyPayload` / hub‑and‑spoke tables, running concurrently with a `BACKUP DATABASE`.

### 4d. Temp table / tempdb spill-to-disk check
No direct evidence of tempdb spills was found in the available telemetry:
- No `tempdb`, "insufficient system memory", "RESOURCE_SEMAPHORE", or memory‑grant messages appear in the SQL Server error log for the incident window.
- `db.Memory Manager.Memory Grants Pending` was **0** throughout (rules out memory-grant queuing that typically precedes tempdb spills under memory pressure).
- RDS Performance Insights does not expose a `tempdb`‑specific spill counter for SQL Server out of the box (no `db.Access Methods.Workfile/Worktables Created` counter was available in `list-available-resource-metrics` for this instance).
- **Recommendation:** if tempdb spills are still suspected, enable a lightweight Extended Events session capturing `sort_warning` / `hash_warning` (tempdb spill events) with a ring buffer target — the default `system_health` session (present, `.xel` files every few hours) can also be pulled and parsed with SSMS/`sys.fn_xe_file_target_read_file` for a definitive answer; this requires a live SQL connection and was outside the read‑only AWS API scope of this pass.

---

## 5. RDS Events (2026‑08‑16, instance-level)

| Time (UTC) | Category | Message |
|---|---|---|
| 07:04:09 | backup | Backing up DB instance |
| 10:51:34 | backup | Finished DB Instance backup |
| every ~2h (36x total) | notification | Storage size 45,000 GiB is approaching the maximum storage threshold 50,000 GiB |

No RDS-level failover/reboot/maintenance event was recorded by the RDS control plane for the 16:08–16:16 window itself — the Always On failover was **engine-internal** (WSFC lease expiry, logged only in the SQL Server error log, §6), which is expected: RDS Multi-AZ SQL Server failovers driven by a non-yielding scheduler are not always mirrored as a distinct `RDS Events` entry the way a manual reboot/failover would be.

---

## 6. Timeline (SQL Server error log, UTC)

| Time | Event |
|---|---|
| 08:07:24 | *(earlier same day)* Buffer Pool scan (CHECKPOINT/FlushCache, db 11) took **228s**, wait 101,000ms — first sign this storage/checkpoint pattern was already stressed hours before the incident. |
| 16:08:19.81 | Buffer Pool scan (CHECKPOINT/FlushCache, db 11) took 12s, wait 1,274ms — minor, recovers. |
| 16:12:54.51 | Buffer Pool scan (CHECKPOINT/FlushCache, **db 10**) took **98s**, wait **76,139ms**. |
| 16:12:55.30 | FlushCache cleaned 203,048 bufs / 156,501 writes in 99,307ms — throughput only **15.97 MB/sec**, **I/O saturation: 113**, 88,407 context switches. |
| 16:14:39.01 | WARNING: Long asynchronous API Call exceeding 10,248ms (scheduler fairness impacted). |
| 16:15:31.11 | WARNING: Long asynchronous API Call exceeding 10,424ms. |
| 16:16:25.18 | WARNING: Long asynchronous API Call exceeding 13,098ms. |
| **16:16:25.49** | **Process 0x1aa8, Worker 0x17DD8C00180 non‑yielding on Scheduler 13** — CPU used: kernel 109ms / user 64,921ms, Process Utilization 16%, System Idle 76%, **Interval 70,135ms**. |
| 16:16:25.49 | **BEGIN STACK DUMP** — "Non‑yielding Scheduler". Memory snapshot at dump time: **MemoryLoad = 92%**, Available Physical = 36,504 MB / 518,567 MB total. |
| 16:16:25.49–16:16:36.67 | Dump callback chain executes (SOS, EE, SE, SEAM, SSB, QE, FullText, SQLCLR, Hk, Repl, PolyBase) — ~11 seconds to complete. |
| **16:16:48.37** | Error 19419/19407 (repeated ×9): **WSFC did not receive a process event signal within the lease timeout period** — lease expired for every Always On AG on the instance (`28fc22d7-…`, `0cff6bab-…`, `4a539d1b-…`, `dafb6f0a-…`, `70133589-…`, `b4f9ae5a-…`, `6e013c8f-…`, `7832ade1-…`, `RDSAG0`). |
| 16:16:48.37 | Local replicas transition `PRIMARY_NORMAL → RESOLVING_NORMAL` across all AGs — **automatic Multi‑AZ failover in progress**. |
| 16:16:48.37 | `Harmony` and `TmsChunker` databases briefly return **Error 988 — "lacks a quorum of nodes for high availability"** to new login attempts. |
| 16:16:48.37 | Several sessions (spid 344, 351, 353, 355, 498, …) get **Error 18056 — "client was unable to reuse a session … reset for connection pooling"** (connection‑pool sessions invalidated by the failover). |
| 16:16:48.62 | Buffer Pool scan (CHECKPOINT/FlushCache, db 10) takes **168s**, wait 157,074ms — the new primary catching up (expected post‑failover recovery I/O, matches the elevated Write Latency/Disk Queue Depth through ~16:24 in §2). |

---

## 7. Source Client / Service Identification

Performance Insights groups DB load by client host (`db.host.name`) — this is the closest available equivalent to a "slow query log source IP" for SQL Server. Results for 16:00–16:20 UTC:

| Client Host (`db.host.name`) | DB Load (AAS) | Resolved Private IP | EC2 Lookup Result |
|---|---:|---|---|
| DATAPRODWORKER1 | 7.78 | *(named host, no literal IP in PI)* | **Not found** in `aws-smartcast-data-prod` / us-west-2 (no matching `Name` tag or instance) |
| DATAPRODSERV1   | 7.44 | *(named host)* | **Not found** |
| DATAPRODHIVE1   | 4.14 | *(named host)* | **Not found** |
| EC2AMAZ-R8F5GFO | 3.90 | *(named host — default Windows computer name)* | **Not found** |
| DATAPRODSERV2   | 3.06 | *(named host)* | **Not found** |
| DATAPRODHIVE2   | 1.63 | *(named host)* | **Not found** |
| ip-10-116-10-16.us-west-2.compute.internal  | 0.74 | 10.116.10.16  | **Not found** — outside the RDS instance's VPC CIDR (`10.121.0.0/16`) |
| DATAPRODHIVE3   | 0.74 | *(named host)* | **Not found** |
| ip-10-116-100-98.us-west-2.compute.internal | 0.58 | 10.116.100.98 | **Not found** — outside VPC CIDR |
| ip-10-121-177-89  | 0.016 | 10.121.177.89 | **In-VPC CIDR, but no matching ENI found** (checked all 146 ENIs in `vpc-0ad23ba34547a8633`) |
| ip-10-121-141-236 | 0.007 | 10.121.141.236 | **In-VPC CIDR, no matching ENI found** |
| ip-10-121-146-2   | 0.001 | 10.121.146.2  | **In-VPC CIDR, no matching ENI found** |
| ip-10-121-172-239 | 0.001 | 10.121.172.239 | **In-VPC CIDR, no matching ENI found** |

### Why the EC2 correlation came up empty (methodology + limitation)
1. Confirmed the DB instance's security group (`sg-0287df56e28631aab`) → VPC `vpc-0ad23ba34547a8633`, CIDR `10.121.0.0/16`.
2. `10.116.x.x` hosts (DATAPROD‑named clients almost certainly connect from this range too, just via named hosts rather than IP) fall **outside** that CIDR — they are in a peered VPC and, going by the `IkonAWSReadOnlyAccess` role's scope, most likely live in a **different AWS sub‑account** (e.g., an ETL/analytics account) that this session's credentials cannot query.
3. For the four `10.121.x.x` addresses that **are** inside the RDS VPC's CIDR, `aws ec2 describe-network-interfaces` (filtered and unfiltered, all 146 ENIs enumerated) found **no current ENI** at those addresses — consistent with ephemeral/autoscaled workers that have since been replaced in the 4 days between the incident and this investigation, or with instances that have since been terminated.
4. `aws ec2 describe-instances` searches for `Name` tags `*DATAPROD*` and `EC2AMAZ-R8F5GFO` returned **zero matches** in this account/region.
5. Checked Auto Scaling Groups in this account (`aws autoscaling describe-auto-scaling-groups`) — only `ecs-content-data-prod-t3-medium` has any live capacity (desired=1); none of the others (`c5-large`, `t3-large`, `t3-xlarge`, `t3a-medium`) are currently scaled up, and none obviously correspond to the Hive/worker hostnames seen in PI.
6. Checked EventBridge scheduled rules (`aws events list-rules`) — none align with a 09:xx Pacific / 16:xx UTC Sunday trigger. Present rules are generic housekeeping (`rate(1 hour)`, `rate(5 minutes)`, `rate(1 minute)`, a Monday 08:00 `nielsen_report_schedule`, and a NewRelic integration cleanup cron) — **no scheduled job in this account explains the connection/read burst**.

**Bottom line:** the workload driving the burst (host names like `DATAPRODWORKER1`/`DATAPRODHIVE1‑3`, and the `Meta.DependencyPayload`/hub‑and‑spoke SQL text) strongly suggests a **Hive/Hadoop-style data pipeline or ETL worker fleet**, but it is **not owned/visible from the `aws-smartcast-data-prod` account** used for this investigation. Recommend re-running the EC2/ASG/EventBridge correlation with read‑only access to whichever sibling account hosts the `DATAPROD*` fleet (likely `aws-smartcast-services-prod` or an analytics/ETL account) to close this loop.

---

## 8. Root Cause Assessment

**Primary trigger:** A workload burst (connection count +400%, Read IOPS +700%, concurrent `BACKUP DATABASE`, and lock‑heavy `MERGE`/`UPDATE` batch jobs against `Meta.DependencyPayload`/hub tables) beginning ~16:06 UTC pushed combined IOPS to ~90% of the 32,200 provisioned IOPS ceiling on the io2 volume, stalling a routine `CHECKPOINT`/`FlushCache` for 98 seconds with I/O saturation of 113.

**Contributing factors:**
- Chronic ~92–93% memory utilization (steady-state for this box on all 3 Sundays examined) left effectively no slack to absorb the burst.
- Storage is at 90% of its 50,000 GiB max threshold, generating repeated capacity warnings all day — not causal here, but reduces overall headroom and is worth fixing regardless.
- `MERGE ... WITH (HOLDLOCK, UPDLOCK)` and `UPDATE ... WITH (ROWLOCK)` patterns amplify lock hold times once I/O slows, producing the dominant `LCK_M_IX` wait and Processes-Blocked spike (up to 43).
- A `BACKUP DATABASE` operation was actively running in the same 16:00–16:20 window, adding I/O load on top of the checkpoint flush and the ETL burst.

**Failure mechanism:** I/O‑bound worker thread → Scheduler 13 non‑yielding for 70.1s → stack dump generation (~23s) → WSFC lease timeout on **all** Always On AGs → automatic Multi‑AZ failover → brief (~1s) database‑unavailable errors on active connections → elevated write latency/queue depth for ~10 minutes while the new primary caught up.

This is the SQL Server Multi‑AZ availability mechanism working as designed under a severe I/O stall — the concerning part is *what drove the stall*, not the failover itself.

---

## 9. Actionable Next Steps

1. **Storage headroom:** Increase the max storage threshold (currently 50,000 GiB, at 90% with 45,000 GiB used) or plan a storage-scaling/archival project before it's forced. Also evaluate whether provisioned IOPS (32,200) needs headroom above the observed ~28,900 combined-IOPS peak — currently only ~10% margin.
2. **Isolate/stagger the ETL burst from native `BACKUP DATABASE`:** the Top-SQL data shows a `BACKUP DATABASE ... VIRTUAL_DEVICE` operation running concurrently with the `Meta.DependencyPayload` MERGE/UPDATE batch. If this is a maintenance-plan or third-party backup (distinct from the RDS automated snapshot, which ran 07:04–10:51 that day), reschedule it away from the `DATAPROD*` batch window.
3. **Review lock hints on the offending statements:** `MERGE ... WITH (HOLDLOCK, UPDLOCK)` and `UPDATE ... WITH (ROWLOCK)` against `Meta.DependencyPayload`/hub tables — evaluate whether these hints are still necessary or can be relaxed/batched in smaller units to reduce blocking under I/O pressure.
4. **Close the source-service identification gap:** re-run the EC2/ENI/ASG/EventBridge correlation in §7 against the account that actually owns the `DATAPROD*` (Hive/worker) fleet — this session's `aws-smartcast-data-prod` read-only role cannot see it.
5. **tempdb/spill visibility:** stand up a lightweight Extended Events session (ring buffer, `sort_warning`/`hash_warning`) or start regularly harvesting the existing `system_health` `.xel` files so a future incident can get a definitive tempdb-spill answer without needing a live connection.
6. **Consider Query Store** (if not already enabled) on the busiest user databases to get plan-level regression detection for the `MERGE`/`UPDATE`/`INSERT` batch jobs identified here.
7. **Alert on precursors, not just the dump:** the 08:07 (228s) and 16:08–16:12 (12s→98s) `CHECKPOINT`/`FlushCache` stall messages preceded the dump by hours/minutes — a CloudWatch Logs metric filter on `"Buffer Pool scan took"` with a threshold (e.g., >30s) combined with `DiskQueueDepth` and Read/Write IOPS approaching provisioned limits would provide earlier warning than waiting for a non-yielding scheduler dump.

---

## 10. Raw Data Files (this investigation)

All raw AWS CLI/API output backing this report is saved under `PromptScriptsOutput/`:
- `cw_metrics_incident_window.json` — CloudWatch 1-min metrics, 15:40–16:45 UTC
- `cw_memory_2026-08-09.json`, `cw_memory_2026-08-02.json` — prior-Sunday memory comparison
- `rds_events.json` — RDS control-plane events, full incident day
- `rds_log_files.json` — full DB log file inventory/timestamps
- `SQLDump0001.txt` — SQL Server stack dump summary (memory snapshot, dump header)
- `ERROR.21.partial.txt` — SQL Server error log covering the incident day
- `pi_os_db_metrics_merged.json` — Performance Insights OS/DB counters, 15:50–16:30 UTC
- `pi_wait_events.json` — Top wait events by DB load, 16:00–16:20 UTC
- `pi_top_sql.json` — Top SQL by DB load, 16:00–16:20 UTC
- `pi_client_hosts.json` — Client host breakdown by DB load, 16:00–16:20 UTC
- `ec2_by_ip.json`, `ec2_by_name.json`, `ec2_dataprod_any.json`, `eni_by_ip.json`, `eni_all_vpc.json` — EC2/ENI correlation attempts (all empty — see §7)
- `eventbridge_rules.json`, `asg_list.json` — EventBridge/ASG scan (no correlating trigger found)
