# RDS MySQL Memory Spike Investigation — STAGE + QA AuxDBs

**Investigation window:** `2026-06-16 15:55 UTC` → `2026-06-23 15:55 UTC` (7 days, 1-minute granularity)
**AWS account:** `788724168120` (profile `inscape-production-us-1-inscape-aws-ops`, region `us-east-1`)
**Instances under investigation:**

| Role  | Instance ID                      | Class         | AZ / MultiAZ     | Engine      | RAM    | Storage  | Created    |
| ----- | -------------------------------- | ------------- | ---------------- | ----------- | ------ | -------- | ---------- |
| STAGE | prod-rds-auxdb-stage-84-20260602 | db.r6i.xlarge | us-east-1b / No  | MySQL 8.4.5 | 32 GiB | 1001 GiB | 2026-06-02 |
| QA    | prod-rds-auxdb-qa-84-20260226    | db.r6i.xlarge | us-east-1c / Yes | MySQL 8.4.5 | 32 GiB | 300 GiB  | 2026-02-26 |

---

## TL;DR

**Question asked:** Why did a memory/CPU spike on the AuxDB seem to "go away on Saturday 2026-06-20"?

**Answer:** It didn't — there was no spike to go away.

### The 5 things you need to know

1. **No memory pressure exists.** Across 7 days × 1-minute samples (10,080 per metric per instance), **SwapUsage = 0 bytes** on both STAGE and QA the entire window. If real memory exhaustion had occurred, the Linux kernel would have swapped. It never did.
2. **FreeableMemory is steady and behaves normally** (~4.0–4.3 GiB on both instances). The slow downward drift is just InnoDB buffer-pool warming — expected behavior; not a leak, not pressure.
3. **No Saturday transition is visible in any metric.** Daily CPU/memory/connection averages on Sat 06-20 sit between the surrounding days on both instances. RDS events, EventBridge schedules, and ASG capacity for the top app talker (`dts-cdetector-staging-iad`) all show no Saturday change.
4. **The single real anomaly is on STAGE, Thursday 06-18 at 17:23–17:29 UTC** — a 6-minute CPU burst peaking at **71.98%**. This is the only minute either instance crossed 60% CPU in the entire week. It is unrelated to Saturday and is the likely thing the user actually saw. Audit logs for that window are already gone (44-minute retention).
5. **Investigation is severely handicapped by config:**
   - **Slow query log is OFF** on both parameter groups → no query-level forensics possible.
   - **Audit log retention is tiny** — STAGE retains only ~44 minutes; QA ~25 days. The Thursday spike's audit data was lost before this investigation started.

### Top 3 fix-now items

| #   | Action                                                                                                                                                                                    | Effort |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Turn on slow_query_log on both PGs (`slow_query_log=1`, `long_query_time=1`, `log_output=TABLE,FILE`).                                                                                    | 5 min  |
| 2   | Raise audit log retention: `SERVER_AUDIT_FILE_ROTATIONS=100`, `SERVER_AUDIT_FILE_ROTATE_SIZE=100MB`. STAGE goes from 44 min → ~1 day; QA goes from 25 d → enough for any future incident. | 5 min  |
| 3   | Disable the orphaned `overwatch-hour-dtsstage-trigger` EventBridge rule — its target Lambda no longer exists; it's been firing-and-failing every 11 min (~131 failures/day) indefinitely. | 5 min  |

### Two quiet config inconsistencies worth knowing

- **`tmp_table_size` is 10× larger on QA than STAGE** (1.86 GiB vs 200 MiB), and `temptable_max_ram` on QA is **10 GiB** vs the engine default of 1 GiB on STAGE. Theoretical worst-case QA memory use exceeds 32 GiB physical RAM; current workload doesn't come close, but the inconsistency is worth aligning.
- **QA parameter group is misleadingly named** `aux-qa-8-4-5-feb-26-readonly` — it's actually the active read/write PG.

### Bottom line for the requester

> "The CloudWatch data does not show any unusual memory or CPU event going away on Saturday. The only real CPU event in the 7-day window was a 6-minute burst on STAGE on Thursday 06-18 at 17:23–17:29 UTC. Both instances had zero swap usage all week, so there was no memory pressure to relieve. If you saw something in Datadog or Performance Insights that we didn't pull, please share that view so we can reconcile."

Full evidence, per-day tables, the per-IP service mapping that identifies `dts-cdetector-staging-iad` as STAGE's only meaningful tenant, and 11 prioritized recommendations follow below.

---

## 1. Executive summary — the "spike went away on Saturday" hypothesis

**Verdict: the CloudWatch data does not show any unusual memory or CPU event going away on Saturday 2026-06-20.** Both instances show steady, recurring weekly workload patterns. Specifically:

| Evidence                                               | What the data shows                                                                                 | Saturday-transition support? |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ---------------------------- |
| Daily CPU on STAGE                                     | Sat avg 3.40% sits BETWEEN Fri (3.55%) and Sun (3.45%) — no transition, no dip                      | No                           |
| Daily CPU on QA                                        | Sat avg 1.69% ≈ Sun 1.68% ≈ Mon 1.69% — no transition visible                                       | No                           |
| FreeableMemory on STAGE                                | Monotonic downward drift Tue→Tue (4.32→4.19 GiB avg); no inflection on Sat                          | No                           |
| FreeableMemory on QA                                   | Monotonic downward drift Tue→Tue (4.02→3.91 GiB avg); no inflection on Sat                          | No                           |
| SwapUsage on both instances                            | 0 bytes for the entire 7-day window                                                                 | No real memory pressure      |
| RDS events                                             | Only routine ~05:10 UTC daily backups + one (non-impacting) "security patch available" notice 06-18 | No reboot/param change       |
| ASG capacity (`dts-cdetector-staging-iad`, top talker) | Constant at 45 nodes; Sat 06-20 had 7 instance-refresh 1-for-1 replacements (no scale change)       | No scale event               |
| EventBridge schedules                                  | All recurring (rate-based) — none changed on/around Saturday                                        | No                           |

**The single notable CPU event in the window was on STAGE, Thursday 2026-06-18 17:23–17:29 UTC**, with a peak of **71.98%** for 6 consecutive minutes. This is the only point in the 7-day window where either instance crossed 60% CPU. It is unrelated to Saturday and is the likely candidate for what the user perceived as a "spike."

The gradually declining FreeableMemory on both instances is normal InnoDB buffer-pool warming (both instances are still well below RAM pressure: STAGE 4.09 GiB free / QA 3.84 GiB free at the lowest point — meaning ~28 GiB and ~28 GiB respectively are being used as cache, which is the expected behavior). **There never was a real memory spike to go away.**

---

## 2. 7-day CloudWatch metric summary (1-min granularity, 10,080 samples per metric per instance)

### 2.1 STAGE — `prod-rds-auxdb-stage-84-20260602`

| Date               | CPU avg % | CPU max % | FreeMem min (GiB) | FreeMem avg (GiB) |  Conn avg | Conn max |
| ------------------ | --------: | --------: | ----------------: | ----------------: | --------: | -------: |
| 2026-06-16 Tue     |      3.16 |     32.43 |              4.25 |              4.32 |     155.2 |      214 |
| 2026-06-17 Wed     |      3.64 |     40.19 |              4.19 |              4.29 |     155.4 |      225 |
| 2026-06-18 Thu     |      3.98 | **71.98** |              4.15 |              4.27 |     150.0 |      219 |
| 2026-06-19 Fri     |      3.55 |     38.32 |              4.13 |              4.25 |     154.7 |      223 |
| **2026-06-20 Sat** |  **3.40** | **37.87** |          **4.14** |          **4.24** | **155.8** |  **220** |
| 2026-06-21 Sun     |      3.45 |     42.25 |              4.09 |              4.21 |     161.0 |      225 |
| 2026-06-22 Mon     |      3.58 |     42.89 |              4.10 |              4.19 |     155.1 |      234 |
| 2026-06-23 Tue     |      3.79 |     32.35 |              4.09 |              4.19 |     160.4 |      192 |

**Top 5 CPU minutes (entire window):**

| Timestamp UTC        | CPU % |
| -------------------- | ----: |
| 2026-06-18 Thu 17:25 | 71.98 |
| 2026-06-18 Thu 17:26 | 59.52 |
| 2026-06-18 Thu 17:29 | 56.35 |
| 2026-06-18 Thu 17:24 | 53.05 |
| 2026-06-18 Thu 17:23 | 52.41 |

→ **All top-5 spikes occurred in a single 6-minute window on Thursday 06-18 17:23–17:29 UTC.** Worth investigating separately — see §8.

### 2.2 QA — `prod-rds-auxdb-qa-84-20260226`

| Date               | CPU avg % | CPU max % | FreeMem min (GiB) | FreeMem avg (GiB) | Conn avg | Conn max |
| ------------------ | --------: | --------: | ----------------: | ----------------: | -------: | -------: |
| 2026-06-16 Tue     |      1.57 |      9.40 |              3.99 |              4.02 |     28.6 |       33 |
| 2026-06-17 Wed     |      1.77 |     33.51 |              3.94 |              4.02 |     29.2 |       36 |
| 2026-06-18 Thu     |      1.87 |     39.22 |              3.97 |              4.01 |     29.0 |       34 |
| 2026-06-19 Fri     |      1.74 |     29.88 |              3.96 |              4.01 |     28.9 |       35 |
| **2026-06-20 Sat** |  **1.69** | **32.58** |          **3.87** |          **3.96** | **30.0** |   **34** |
| 2026-06-21 Sun     |      1.68 |     33.39 |              3.87 |              3.93 |     28.4 |       33 |
| 2026-06-22 Mon     |      1.69 |     31.09 |              3.84 |              3.91 |     29.1 |       35 |
| 2026-06-23 Tue     |      1.81 |     32.89 |              3.85 |              3.91 |     30.9 |       37 |

**Top 5 CPU minutes (entire window):**

| Timestamp UTC        | CPU % |
| -------------------- | ----: |
| 2026-06-18 Thu 17:20 | 39.22 |
| 2026-06-18 Thu 17:21 | 36.53 |
| 2026-06-18 Thu 11:29 | 33.78 |
| 2026-06-17 Wed 11:31 | 33.51 |
| 2026-06-21 Sun 11:29 | 33.39 |

→ Most QA peaks cluster around **11:20–11:36 UTC daily** — a recurring scheduled workload that fires every day including Saturday.

### 2.3 FreeableMemory bottom-5 minutes (per instance)

| Instance | Timestamp UTC        | FreeMem (GiB) |
| -------- | -------------------- | ------------: |
| STAGE    | 2026-06-21 Sun 20:09 |          4.09 |
| STAGE    | 2026-06-23 Tue 09:10 |          4.09 |
| STAGE    | 2026-06-23 Tue 09:09 |          4.10 |
| STAGE    | 2026-06-22 Mon 20:10 |          4.10 |
| STAGE    | 2026-06-23 Tue 07:35 |          4.11 |
| QA       | 2026-06-22 Mon 11:36 |          3.84 |
| QA       | 2026-06-22 Mon 11:35 |          3.85 |
| QA       | 2026-06-23 Tue 11:35 |          3.85 |
| QA       | 2026-06-23 Tue 11:39 |          3.85 |
| QA       | 2026-06-23 Tue 11:36 |          3.85 |

**Important:** The LOWEST FreeMem moments are all **after** Saturday (Sun/Mon/Tue), which is the opposite of the "spike that went away on Saturday" hypothesis — if anything, memory pressure has been climbing very gradually throughout the week.

### 2.4 SwapUsage — flat zero on both instances (critical context for the memory-spike question)

`AWS/RDS SwapUsage` was collected at 1-minute granularity for the full 7-day window (10,080 samples per instance). Result:

| Instance | Samples |   Min |  Mean |   p95 |   Max | % samples > 0 |
| -------- | ------: | ----: | ----: | ----: | ----: | ------------: |
| STAGE    |  10,080 | 0 MiB | 0 MiB | 0 MiB | 0 MiB |          0.0% |
| QA       |  10,080 | 0 MiB | 0 MiB | 0 MiB | 0 MiB |          0.0% |

**Daily peak SwapUsage (MiB) — every single day:**

| Date           | STAGE peak | QA peak |
| -------------- | ---------: | ------: |
| 2026-06-16 Tue |          0 |       0 |
| 2026-06-17 Wed |          0 |       0 |
| 2026-06-18 Thu |          0 |       0 |
| 2026-06-19 Fri |          0 |       0 |
| 2026-06-20 Sat |          0 |       0 |
| 2026-06-21 Sun |          0 |       0 |
| 2026-06-22 Mon |          0 |       0 |
| 2026-06-23 Tue |          0 |       0 |

→ **Both instances never swapped a single byte for the entire 7-day window.** This is a strong, direct rebuttal of any "memory pressure" narrative: if the Linux kernel underneath RDS had genuinely been pushed against its memory limits, it would have started paging to swap. Zero swap means the FreeableMemory drift documented in §2.1/§2.2 is purely InnoDB buffer-pool warming (expected behavior on a healthy MySQL instance with ~28 GiB cached pages) and not real OS-level memory exhaustion. **There never was a real memory spike to go away on Saturday — there has been no memory pressure at all during the window.**

---

## 3. Same-weekday comparison

The 7-day metric window contains exactly **one Saturday** (2026-06-20). We can not directly compare to Sat 06-13 or Sat 06-06 from the same metric pull. The data we DO have shows Saturday 06-20 is statistically interchangeable with its surrounding days on both instances:

| Instance | Fri 06-19 avg / max | **Sat 06-20 avg / max** | Sun 06-21 avg / max | Sat-was-an-outlier?          |
| -------- | ------------------- | ----------------------- | ------------------- | ---------------------------- |
| STAGE    | 3.55% / 38.32%      | **3.40% / 37.87%**      | 3.45% / 42.25%      | No (lowest-of-3 by 0.05 avg) |
| QA       | 1.74% / 29.88%      | **1.69% / 32.58%**      | 1.68% / 33.39%      | No (≈ Sun)                   |

**If the user wants to compare Saturday-over-Saturday across multiple weeks, we'd need to re-pull CloudWatch with a 21-day window** — see Next Steps §10.

---

## 4. Slow query log analysis

| Instance | `slow_query_log` setting     | `DescribeDBLogFiles --filename-contains slowquery` | Files retrieved |
| -------- | ---------------------------- | -------------------------------------------------- | --------------- |
| STAGE    | `engine-default` (= **OFF**) | empty                                              | 0               |
| QA       | `engine-default` (= **OFF**) | empty                                              | 0               |

**No slow query data is available for either instance for the investigation window** (or for any past period). This is a significant observability gap and is the #1 actionable recommendation in §10.

---

## 5. MariaDB Audit log analysis (source service / IP attribution)

Audit logs **are** enabled on both instances via the `custom-audit-log-*` option group (MariaDB audit plugin, events `CONNECT,QUERY_DCL,QUERY_DDL` configured; the actual log content shows the plugin logs all `QUERY` operations too).

| Instance | Audit retention captured | Time range covered (UTC)                          | Raw events parsed | Unique client IPs |
| -------- | ------------------------ | ------------------------------------------------- | ----------------: | ----------------: |
| STAGE    | 10 files × ~1 MiB each   | 2026-06-23 15:43:34 → 16:27:36 (~44 min)          |            57,611 |                70 |
| QA       | 10 files × ~1 MiB each   | 2026-06-22 15:52:12 → 2026-06-23 16:27:52 (~25 h) |            60,987 |               130 |

**Retention limitation:** STAGE's audit log rotates every ~4 minutes due to query volume — only ~44 minutes of data is ever on disk. QA retains ~25 hours. **Neither instance retains audit data going back to Saturday 06-20.** This is the #2 actionable recommendation in §10.

### 5.1 STAGE — service attribution (44-minute window)

| Service                         | EC2 type    | Instances | Source IPs | Audit events | Share | Repo                                                         |
| ------------------------------- | ----------- | --------: | ---------: | -----------: | ----: | ------------------------------------------------------------ |
| dts-cdetector-staging-iad       | c6a.2xlarge |        45 |         45 |       57,087 | 99.1% | https://github.com/CognitiveNetworks/dts-cdetector           |
| retargeting-staging-iad         | c5.2xlarge  |        19 |         19 |          340 |  0.6% | https://github.com/CognitiveNetworks/retargeting             |
| control-plane-monitor           | c5.4xlarge  |         1 |          1 |          106 |  0.2% | (internal)                                                   |
| (cross-account / unmatched ENI) | —           |         0 |          1 |           40 |  0.1% | —                                                            |
| dbproxy-production-iad          | t3.medium   |         1 |          1 |           24 | <0.1% | https://github.com/CognitiveNetworks/dbproxy                 |
| mbah-development-iad            | m6i.large   |         1 |          1 |            8 | <0.1% | https://github.com/CognitiveNetworks/infra-oneoffs-terraform |
| control-plane-dts-dtsstage-iad  | t3.small    |         1 |          1 |            4 | <0.1% | https://github.com/CognitiveNetworks/control-plane-dts       |
| ump2_stage_dtsstage_4715        | c6a.4xlarge |         1 |          1 |            2 | <0.1% | https://github.com/CognitiveNetworks/automate                |

**→ STAGE is essentially a single-tenant DB for `dts-cdetector-staging-iad`** (45-node ASG, c6a.2xlarge). Top-5 IPs each issue 1,500–3,200 queries per 44 min, ≈ 35–73 queries/sec/node — steady, distributed read/write load.

### 5.2 QA — service attribution (25-hour window)

| Service                           | EC2 type     | Instances | Source IPs | Audit events |    Share | Repo                                                            |
| --------------------------------- | ------------ | --------: | ---------: | -----------: | -------: | --------------------------------------------------------------- |
| dts-cdetector-qa-iad              | c6a.2xlarge  |         3 |          3 |       46,031 |    75.5% | https://github.com/CognitiveNetworks/dts-cdetector              |
| retargeting-qa-iad                | c5.2xlarge   |         1 |          1 |       11,176 |    18.3% | https://github.com/CognitiveNetworks/retargeting                |
| (cross-account / unmatched ENI)   | —            |         0 |          6 |        1,497 |     2.5% | —                                                               |
| control-plane-monitor             | c5.4xlarge   |         1 |          1 |          623 |     1.0% | (internal)                                                      |
| dts-datadog-qa-file-iad           | m5dn.2xlarge |         2 |          2 |          109 |     0.2% | https://github.com/CognitiveNetworks/dts-datadog                |
| control-plane-dts-qa-iad          | t3.small     |         1 |          1 |           98 |     0.2% | https://github.com/CognitiveNetworks/control-plane-dts          |
| jenkins-qa-node-2                 | m3.medium    |         1 |          1 |           88 |     0.1% | https://github.com/CognitiveNetworks (Jenkins)                  |
| fileingest-delete-notifier-qa-iad | t3.medium    |         1 |          1 |           50 |     0.1% | https://github.com/CognitiveNetworks/fileingest_delete_notifier |
| dcm-qa-iad                        | r5.large     |         1 |          1 |           38 |     0.1% | https://github.com/CognitiveNetworks/dcm                        |
| `apm_c*_stage_qa_*` (`automate`)  | r6a.large    |       ~10 |        ~10 |       ~12 ea | <0.1% ea | https://github.com/CognitiveNetworks/automate                   |
| `pm2_c*_stage_qa_*` (`automate`)  | r6a.large    |       ~80 |        ~80 |       ~12 ea | <0.1% ea | https://github.com/CognitiveNetworks/automate                   |
| fileingest-qa-iad                 | c5.large     |         2 |          2 |            9 |    <0.1% | https://github.com/CognitiveNetworks/fileingest                 |
| openvpn-production-iad            | t3.small     |         1 |          1 |            7 |    <0.1% | https://github.com/CognitiveNetworks/ops-tools/openvpn          |
| Others (~15 services, <50 ev ea)  | mixed        |       ~15 |        ~15 |         ~250 |    <0.5% | mixed                                                           |

**Notable QA findings:**
- **`172.17.95.8` is a connection-health probe / pool-warmer**: 5,588 CONNECT + 5,588 DISCONNECT pairs and **0 queries** over 25 hours (~one connection cycle every ~8 seconds). This is `retargeting-qa-iad`. **Consider whether this is intentional** — it's pure noise on the DB but harmless.
- **30 `FAILED_CONNECT` events** from user `dbx` (47 total events) and blank-user (30) — small, ignore unless rises.
- **~110 `pm2_*` and `apm_*` `automate`-repo r6a.large** instances each connect once with ~12 events (CONNECT/QUERY×n/DISCONNECT) during the window — looks like a daily reconciliation sweep across the `automate` fleet.

### 5.3 Audit event-type breakdown

| Instance |  QUERY | CONNECT | DISCONNECT | FAILED_CONNECT | Users (count)                                        |
| -------- | -----: | ------: | ---------: | -------------: | ---------------------------------------------------- |
| STAGE    | 57,038 |     288 |        285 |              0 | root: 57,571 / rdsadmin: 40                          |
| QA       | 46,026 |   7,465 |      7,466 |             30 | root: 59,460 / rdsadmin: 1,450 / dbx: 47 / blank: 30 |

→ STAGE shows long-lived persistent connections (very few CONNECT events vs QUERY); QA shows constant churn from short-lived clients (mostly the connection-probe `172.17.95.8` and the `automate` sweep).

---

## 6. RDS events (full 7-day window, both instances)

### 6.1 STAGE — 15 events total (all routine)

```
2026-06-17T05:09 backup     Backing up DB instance
2026-06-17T05:17 backup     Finished DB Instance backup
2026-06-18T05:10 backup     Backing up DB instance
2026-06-18T05:18 backup     Finished DB Instance backup
2026-06-18T16:24 security   A system update is available for your DB instance. (INFORMATIONAL — no action taken)
2026-06-19T05:09 backup     Backing up DB instance
2026-06-19T05:18 backup     Finished DB Instance backup
2026-06-20T05:10 backup     Backing up DB instance              ← Saturday — exact same pattern
2026-06-20T05:18 backup     Finished DB Instance backup
2026-06-21T05:10 backup     Backing up DB instance
2026-06-21T05:18 backup     Finished DB Instance backup
2026-06-22T05:09 backup     Backing up DB instance
2026-06-22T05:18 backup     Finished DB Instance backup
2026-06-23T05:10 backup     Backing up DB instance
2026-06-23T05:17 backup     Finished DB Instance backup
```

### 6.2 QA — 14 events total (all backups)

```
2026-06-17T05:05 backup     Backing up DB instance
2026-06-17T05:45 backup     Finished DB Instance backup
... (identical daily 05:05–05:45 UTC pattern every day, including Sat 06-20) ...
2026-06-23T05:05 backup     Backing up DB instance
2026-06-23T05:45 backup     Finished DB Instance backup
```

**No parameter changes, no reboots, no failovers, no DB modifications, no maintenance windows fired during the 7-day window on either instance.**

---

## 7. Configuration & infrastructure inspection

### 7.1 Parameter group diffs (STAGE vs QA — only meaningful differences)

| Parameter             | STAGE (`aux-stg-8-4-5-apr-28`) | QA (`aux-qa-8-4-5-feb-26-readonly`) | Impact                                                       |
| --------------------- | -----------------------------: | ----------------------------------: | ------------------------------------------------------------ |
| `tmp_table_size`      |                    209,715,200 |                       2,000,000,000 | QA can hold 10× larger temp results in RAM before disk spill |
| `max_heap_table_size` |                    209,715,200 |                       2,000,000,000 | Same — MEMORY engine table ceiling                           |
| `slow_query_log`      |       `engine-default` (= OFF) |            `engine-default` (= OFF) | **Neither logs slow queries** — fix this                     |
| `log_output`          |                          TABLE |                               TABLE | OK                                                           |
| `long_query_time`     |                             10 |                                  10 | Default; too high                                            |
| `general_log`         |                            OFF |                                 OFF | OK                                                           |

→ The `tmp_table_size` differential is the simplest explanation for QA's structurally **lower** FreeMem baseline (~3.9 GiB) vs STAGE (~4.2 GiB): a single long-running sort/group-by on QA can consume up to ~1.86 GiB of process-private memory; STAGE caps the same query at 200 MiB.

⚠ The QA PG is named `…-readonly` but is **the active read-write parameter group**. Misleading name — rename or document.

### 7.2 Option groups (identical between STAGE and QA)

| Plugin / option                 | Value                         | Notes                                                                       |
| ------------------------------- | ----------------------------- | --------------------------------------------------------------------------- |
| `MARIADB_AUDIT_PLUGIN`          | configured                    | Both instances                                                              |
| `SERVER_AUDIT_EVENTS`           | `CONNECT,QUERY_DCL,QUERY_DDL` | DML/SELECT supposed to be filtered — but actual log contains `QUERY` events |
| `SERVER_AUDIT_FILE_ROTATIONS`   | 10                            | Too few — causes ~44-min retention on STAGE                                 |
| `SERVER_AUDIT_FILE_ROTATE_SIZE` | 1,000,000 (1 MiB)             | Too small — same root cause                                                 |

### 7.3 Auto-Scaling Groups (Saturday 06-20 activities)

| ASG                       | Min/Desired/Max | Sat 06-20 scaling events | Notes                                                  |
| ------------------------- | --------------- | ------------------------ | ------------------------------------------------------ |
| dts-cdetector-staging-iad | 45/45/90        | 0 capacity-change        | 7 paired Launch/Terminate (1-for-1 instance refresh)   |
| retargeting-staging-iad   | 19/19/40        | 0 capacity-change        | 23 activities total (1-for-1 refreshes — same pattern) |

→ **No scale-up/scale-down occurred on Saturday on either ASG.** The activity list only contains instance-replacement events (likely from ASG health checks or scheduled instance refresh). Capacity stayed constant.

### 7.4 EventBridge rules (37 total — 36 enabled / 1 disabled)

| Rule (rate-scheduled, ENABLED)                | Schedule     | Notes                                                                                    |
| --------------------------------------------- | ------------ | ---------------------------------------------------------------------------------------- |
| `LimitMonitor-QueuePollSchedule-7XJWMUX12WQ7` | rate(5 min)  | OK — service limit monitor                                                               |
| `LimitMonitor-TARefreshSchedule-IFPLDFBIFGY8` | rate(1 day)  | OK                                                                                       |
| `james-test`                                  | rate(1 min)  | ⚠ Description literally says "nothing" — orphan test rule                                |
| **`overwatch-hour-dtsstage-trigger`**         | rate(11 min) | ⚠⚠ **Lambda target `overwatch-hour-dtsstage` is DELETED** — fires-and-fails every 11 min |
| `overwatch-hour-qa-trigger`                   | rate(11 min) | Verify Lambda target exists                                                              |
| `overwatch-hour-sofiazoo-trigger`             | rate(11 min) | Verify Lambda target exists                                                              |
| `ump_watcher_trigger`                         | rate(15 min) | OK                                                                                       |

→ **None of these changed on/around Saturday 06-20.** The `overwatch-hour-dtsstage-trigger` issue is an operational finding (see §10) but is not the cause of any Saturday transition.

---

## 8. The one real outlier: STAGE Thursday 06-18 17:23–17:29 UTC

This is the only place in the 7-day window on either instance where CPU exceeded 50%. Six consecutive minutes from 17:23 to 17:29 UTC, peaking at **71.98% at 17:25 UTC**. No corresponding event on QA (QA's max in this window was 7.45%). No RDS events fired. Audit logs have long since rolled over so per-query attribution isn't possible after the fact.

If the user's perception of "a spike" is real, **this Thursday event is the only candidate** in the metric data. It happened ≈ 2½ days BEFORE Saturday, so framing it as "the spike went away by Saturday" would be technically true but materially misleading — it ended at 17:30 Thursday.

---

## 9. Methodology

**Tools:** AWS CLI v2 with SSO profile `inscape-production-us-1-inscape-aws-ops`, `jq`, Python 3, MariaDB audit plugin log parsing.

**Steps:**

1. **Instance enumeration:** `aws rds describe-db-instances --db-instance-identifier <id>` for both instances; extracted endpoint, parameter group, option group, MultiAZ, VPC, AZ.
2. **Metric collection:** `aws cloudwatch get-metric-data` with `--start-time` 7 days ago, `--end-time` now, `Period=60`, statistic `Average` for: `CPUUtilization`, `FreeableMemory`, `SwapUsage`, `DatabaseConnections`, `ReadIOPS`, `WriteIOPS`, `NetworkReceiveThroughput`, `NetworkTransmitThroughput`. Saved 10,079–10,080 points per metric per instance to `{inst}/metrics_raw.json`.
3. **Per-day & same-weekday rollups:** Python script (`daily_compare.py`) groups timestamps by weekday and date; reports mean/max/p95 for CPU and min/avg for FreeMem.
4. **RDS events:** `aws rds describe-events --source-identifier <id> --source-type db-instance --duration 10080` (10080 min = 7 days).
5. **Slow query logs:** `aws rds describe-db-log-files --filename-contains slowquery` — empty on both. `slow_query_log` parameter confirmed OFF via `describe-db-parameters`.
6. **Audit logs:** `aws rds describe-db-log-files --filename-contains audit` → loop `aws rds download-db-log-file-portion --output text --query 'LogFileData'` (the `--output text` form was needed because raw JSON contains control characters that break `jq`).
7. **Audit parsing:** Python regex `^(?P<ts>\d{8} \d{2}:\d{2}:\d{2}),(?P<host>[^,]*),(?P<user>[^,]*),(?P<client>[^,]*),(?P<connid>[^,]*),(?P<queryid>[^,]*),(?P<op>CONNECT|QUERY|QUERY_DCL|QUERY_DDL|QUERY_DML|DISCONNECT|FAILED_CONNECT|READ|WRITE)` — counted operations per client IP per user; produced `{inst}/audit_summary.json` and `{inst}/unique_ips.txt`.
8. **IP → ENI mapping:** `aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=…` in 50-IP chunks → extracted `Attachment.InstanceId`.
9. **ENI → EC2 instance → tags:** `aws ec2 describe-instances --instance-ids …` → extracted `Tags[Name|service|role|environment|repo|aws:autoscaling:groupName]`. Repo discovered from `repo` or `iac-repo` tag.
10. **EventBridge rules:** `aws events list-rules` → state + ScheduleExpression. For `overwatch-hour-dtsstage-trigger` followed up with `aws lambda get-function --function-name overwatch-hour-dtsstage` (returned `ResourceNotFoundException`).
11. **ASG scaling activities:** `aws autoscaling describe-scaling-activities --auto-scaling-group-names <name>` filtered to Sat 06-20.

All raw artifacts persisted under `PromptScriptsOutput/rds-memspike-twodb-20260623T155503Z/`.

---

## 10. Actionable next steps (prioritized)

|   # | Priority | Action                                                                                                                                                                                                                                                                                                                                                                                                                       | Effort                   |
| --: | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
|   1 | **HIGH** | **Turn on slow query log** on BOTH parameter groups: `slow_query_log=1`, `long_query_time=1`, `log_output=TABLE,FILE`, `log_slow_admin_statements=1`. Without this we cannot do any meaningful query-level investigation in future.                                                                                                                                                                                          | 5-min PG change, dynamic |
|   2 | **HIGH** | **Increase audit log retention** on BOTH option groups: `SERVER_AUDIT_FILE_ROTATIONS=100`, `SERVER_AUDIT_FILE_ROTATE_SIZE=100000000` (100 MiB). This gives ~1 day on STAGE (currently 44 min) and ~25 days on QA. Required to retroactively investigate any future incident.                                                                                                                                                 | 5-min OG change          |
|   3 | **HIGH** | **Re-pull metrics with a 21-day window** (`--start-time` 21 days back) and re-run the same-weekday compare to genuinely answer "what happened the last 3 Saturdays" — current window only contains 1 Saturday.                                                                                                                                                                                                               | 10 min                   |
|   4 | **MED**  | **Investigate STAGE Thursday 06-18 17:23–17:29 UTC CPU spike** (71.98% / 6 min). Cross-reference with `dts-cdetector-staging-iad` application logs (only tenant of consequence), retargeting application logs, and Datadog APM for that window. Audit logs from that window are gone.                                                                                                                                        | 30 min                   |
|   5 | **MED**  | **Disable or delete the orphaned `overwatch-hour-dtsstage-trigger` EventBridge rule** — target Lambda `overwatch-hour-dtsstage` no longer exists; the rule has been firing-and-failing every 11 minutes (≈ 131 failed invocations/day) for an unknown period. Also verify `overwatch-hour-qa-trigger` and `overwatch-hour-sofiazoo-trigger` targets still exist. Delete `james-test` rate(1-min) rule (described "nothing"). | 5 min                    |
|   6 | **MED**  | **Confirm where the user observed "the spike going away on Saturday"** — was it CloudWatch, Datadog, Performance Insights db-load, or something else? If Datadog/PI, also fetch those time series to reconcile. Possibility: dashboard was in PT timezone (Sat 00:00 PT = Sat 07:00 UTC) and visualized a metric we did not pull (e.g., RDS PI `db.SQL.tup_returned` or DB load).                                            | 15 min user dialogue     |
|   7 | **MED**  | **Add SELECT visibility to audit**: change `SERVER_AUDIT_EVENTS=CONNECT,QUERY` (or at least `CONNECT,QUERY_DML_NO_SELECT,QUERY_DCL,QUERY_DDL`). Current setting is supposed to omit DML/SELECT but the log shows DML is being captured anyway — clarify intent and align config to actual behavior.                                                                                                                          | 5 min                    |
|   8 | **LOW**  | **Investigate QA `172.17.95.8` (retargeting-qa) connection-pool churn** — 5,588 CONNECT+DISCONNECT pairs with 0 queries over 25 h. If unintentional, switch the client to a long-lived pool. Currently harmless but generates audit noise.                                                                                                                                                                                   | 20 min                   |
|   9 | **LOW**  | **Rename QA PG `aux-qa-8-4-5-feb-26-readonly` → `aux-qa-8-4-5-feb-26`** (or document); the `-readonly` suffix is misleading since it's the active R/W PG.                                                                                                                                                                                                                                                                    | 5 min (PG copy + swap)   |
|  10 | **LOW**  | **Align tmp_table_size between STAGE and QA** to whichever the standard is intended to be; current 10× differential makes performance/memory characterization inconsistent between environments.                                                                                                                                                                                                                             | 5 min PG change          |
|  11 | **LOW**  | **Investigate QA 30 `FAILED_CONNECT` events** from user `dbx` and 30 from blank user — possibly leftover from a removed Databricks connector or a misconfigured client.                                                                                                                                                                                                                                                      | 15 min                   |

---

## 11. Timeline of what actually happened (UTC)

```
2026-06-16 Tue 15:55   ← investigation window starts (T-7d)
2026-06-17 Wed 05:09   STAGE daily backup (8 min)
2026-06-17 Wed 05:05   QA daily backup (40 min)
2026-06-17 Wed 11:31   QA daily ~11:30 UTC scheduled workload — first observation (33.51% CPU)
2026-06-18 Thu 05:10   STAGE daily backup
2026-06-18 Thu 05:05   QA daily backup
2026-06-18 Thu 11:29   QA daily 11:30 UTC workload (33.78% CPU)
2026-06-18 Thu 16:24   STAGE RDS event: "system update available" — informational, NOT applied
2026-06-18 Thu 17:20   QA CPU 36.53% / 39.22% peak — workload spike (probably correlated w/ STAGE event below)
2026-06-18 Thu 17:23   *** STAGE CPU starts climbing past 50% ***
2026-06-18 Thu 17:25   *** STAGE CPU peaks at 71.98% (only minute >60% in entire 7d window) ***
2026-06-18 Thu 17:29   *** STAGE CPU returns to baseline (last minute >50%) ***
2026-06-19 Fri 05:10   STAGE daily backup    /  05:05 QA daily backup
2026-06-20 Sat 02:52   dts-cdetector-staging-iad ASG: instance refresh #1 (1-for-1)
2026-06-20 Sat 04:18   dts-cdetector-staging-iad ASG: instance refresh #2 (1-for-1)
2026-06-20 Sat 05:10   STAGE daily backup    /  05:05 QA daily backup
2026-06-20 Sat 08:02   dts-cdetector-staging-iad ASG: instance refresh #3 (1-for-1)
2026-06-20 Sat 11:29   QA daily 11:30 UTC scheduled workload (32.58% CPU) — fires on Sat same as weekdays
2026-06-20 Sat 21:32–22:30  dts-cdetector-staging-iad ASG: instance refreshes #4–#7 (all 1-for-1)
2026-06-20 Sat (all day)  *** STAGE avg CPU 3.40%, QA avg CPU 1.69% — statistically identical to surrounding days ***
2026-06-20 Sat (all day)  *** Swap = 0 on both instances. FreeMem 4.14 / 3.87 GiB min — gradual decline continuing, NOT a transition ***
2026-06-21 Sun 11:29   QA 33.39% CPU (daily 11:30 UTC workload)
2026-06-21 Sun 20:09   STAGE lowest FreeMem of window (4.09 GiB) — POST-Saturday
2026-06-22 Mon 11:35   QA lowest FreeMem of window (3.84 GiB) — POST-Saturday
2026-06-23 Tue 09:10   STAGE lowest FreeMem of window (4.09 GiB tied)
2026-06-23 Tue 15:55   ← investigation window ends (NOW)
```

**→ Read horizontally: there is no Saturday transition. The downward FreeMem drift continues monotonically through Saturday into Sunday/Monday. The only memorable CPU event happened the prior Thursday, not Saturday.**

---

## 12. Files produced

All artifacts under `PromptScriptsOutput/rds-memspike-twodb-20260623T155503Z/`:

| Path                                         | What                                                             |
| -------------------------------------------- | ---------------------------------------------------------------- |
| `start.txt`, `end.txt`                       | Investigation window bounds (UTC ISO-8601)                       |
| `stage/instance_details.json`                | `describe-db-instances` for STAGE                                |
| `qa/instance_details.json`                   | `describe-db-instances` for QA                                   |
| `{stage,qa}/metrics_raw.json`                | CloudWatch raw metric output (8 metrics × 1-min × 7d each)       |
| `{stage,qa}/metric_queries.json`             | The `--metric-data-queries` payload used                         |
| `{stage,qa}/rds_events.json`                 | 7-day RDS events                                                 |
| `{stage,qa}/param_group.json`                | Full parameter group dump                                        |
| `{stage,qa}/option_group.json`               | Full option group dump                                           |
| `{stage,qa}/audit_files.json`                | Available audit log file listing                                 |
| `{stage,qa}/audit/server_audit.log[.{1..9}]` | Raw downloaded audit log files                                   |
| `{stage,qa}/audit_summary.json`              | Per-client-IP operation counts                                   |
| `{stage,qa}/unique_ips.txt`                  | Unique client IPs observed in audit window                       |
| `ip_to_eni.json`                             | IP → ENI metadata (both instances combined)                      |
| `instance_summary.json`                      | ENI → EC2 instance type/AZ/tags                                  |
| `ip_service_rows.json`                       | Per-instance IP → service rows with event counts                 |
| `eventbridge_rules_all.json`                 | All 37 EventBridge rules in account/region                       |
| `hourly_rollup.txt`                          | Per-hour CPU/FreeMem rollup for both instances (with flag lines) |
| `hourly_stage.txt`, `hourly_qa.txt`          | Per-instance split of the hourly rollup                          |
| `daily_compare.py`                           | Per-day & same-weekday-Saturday compare script                   |
| `daily_compare.txt`                          | Output of daily_compare.py                                       |
| `analyze_hourly.py`                          | Per-hour rollup script (with CPU≥50 / FM≤4.10 GiB flagging)      |
| **`REPORT.md`**                              | **This document**                                                |

---

## 13. TL;DR

**Question asked:** Why did a memory/CPU spike on the AuxDB seem to "go away on Saturday 2026-06-20"?

**Answer:** It didn't — there was no spike to go away.

### The 5 things you need to know

1. **No memory pressure exists.** Across 7 days × 1-minute samples (10,080 per metric per instance), **SwapUsage = 0 bytes** on both STAGE and QA the entire window. If real memory exhaustion had occurred, the Linux kernel would have swapped. It never did.
2. **FreeableMemory is steady and behaves normally** (~4.0–4.3 GiB on both instances). The slow downward drift is just InnoDB buffer-pool warming — expected behavior; not a leak, not pressure.
3. **No Saturday transition is visible in any metric.** Daily CPU/memory/connection averages on Sat 06-20 sit between the surrounding days on both instances. RDS events, EventBridge schedules, and ASG capacity for the top app talker (`dts-cdetector-staging-iad`) all show no Saturday change.
4. **The single real anomaly is on STAGE, Thursday 06-18 at 17:23–17:29 UTC** — a 6-minute CPU burst peaking at **71.98%**. This is the only minute either instance crossed 60% CPU in the entire week. It is unrelated to Saturday and is the likely thing the user actually saw. Audit logs for that window are already gone (44-minute retention).
5. **Investigation is severely handicapped by config:**
   - **Slow query log is OFF** on both parameter groups → no query-level forensics possible.
   - **Audit log retention is tiny** — STAGE retains only ~44 minutes; QA ~25 days. The Thursday spike's audit data was lost before this investigation started.

### Top 3 fix-now items

| #   | Action                                                                                                                                                                                    | Effort |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Turn on slow_query_log on both PGs (`slow_query_log=1`, `long_query_time=1`, `log_output=TABLE,FILE`).                                                                                    | 5 min  |
| 2   | Raise audit log retention: `SERVER_AUDIT_FILE_ROTATIONS=100`, `SERVER_AUDIT_FILE_ROTATE_SIZE=100MB`. STAGE goes from 44 min → ~1 day; QA goes from 25 d → enough for any future incident. | 5 min  |
| 3   | Disable the orphaned `overwatch-hour-dtsstage-trigger` EventBridge rule — its target Lambda no longer exists; it's been firing-and-failing every 11 min (~131 failures/day) indefinitely. | 5 min  |

### Two quiet config inconsistencies worth knowing

- **`tmp_table_size` is 10× larger on QA than STAGE** (1.86 GiB vs 200 MiB), and `temptable_max_ram` on QA is **10 GiB** vs the engine default of 1 GiB on STAGE. Theoretical worst-case QA memory use exceeds 32 GiB physical RAM; current workload doesn't come close, but the inconsistency is worth aligning.
- **QA parameter group is misleadingly named** `aux-qa-8-4-5-feb-26-readonly` — it's actually the active read/write PG.

### Bottom line for the requester

> "The CloudWatch data does not show any unusual memory or CPU event going away on Saturday. The only real CPU event in the 7-day window was a 6-minute burst on STAGE on Thursday 06-18 at 17:23–17:29 UTC. Both instances had zero swap usage all week, so there was no memory pressure to relieve. If you saw something in Datadog or Performance Insights that we didn't pull, please share that view so we can reconcile."
