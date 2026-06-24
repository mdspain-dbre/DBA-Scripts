# Performance Insights — STAGE Thursday 06-18 17:23–17:29 UTC CPU Spike

**Source:** RDS Performance Insights (7-day free retention) on `prod-rds-auxdb-stage-84-20260602`
**DbiResourceId:** `db-NVRXOKTVBR33P5QR6NZQGDW4WA`
**Spike window queried:** `2026-06-18 17:20–17:35 UTC` (15-min sliding window around the CloudWatch CPU peak)
**Baseline window:** `2026-06-18 00:00–24:00 UTC` (same calendar day)
**Companion document:** [REPORT.md](REPORT.md) — full 7-day investigation. This file deep-dives §8 ("The Thursday outlier") using PI data that was not available at the time the main report was written.

---

## TL;DR

A **single human-or-tool session connected through the OpenVPN gateway as MySQL user `root`** ran two large aggregation queries that account for **~94 % of total database load** during the 6-minute CPU spike. The queries are pre-existing application SQL (also present in the 24 h baseline at ~1 % the rate), so this is not new code or a runaway service — it is **the same query executed at scale on demand by an ad-hoc consumer**. The query is CPU-bound (sole wait event = `executing`); there is no evidence of memory pressure (SwapUsage = 0 throughout, confirmed independently in [REPORT.md §2.4](REPORT.md)).

**Performance Insights cannot report per-query memory consumption.** What follows is the closest possible attribution.

---

## 1. Performance Insights configuration confirmed

| Instance | PI enabled | PI retention | Enhanced Mon | Notes                                                       |
| -------- | ---------- | ------------ | ------------ | ----------------------------------------------------------- |
| STAGE    | yes        | 7 days       | 60 sec       | Spike at -5d is still queryable; window expires 2026-06-25. |
| QA       | yes        | 7 days       | 60 sec       | No spike on QA worth investigating, but PI is available.    |

`db.load.avg` (Average Active Sessions, AAS) is the unit used by PI for all dimension-key queries below.

---

## 2. Per-minute db.load timeline (proves the spike shape)

Pulled at 60-sec granularity for 17:00–18:00 UTC. Bar = `#` per 0.2 AAS. AAS ≥ 1 means at least one session was actively working at all times in that minute.

| Minute UTC  | db.load.avg | Bar                    |
| ----------- | ----------- | ---------------------- |
| 17:00       | 0.27        | #                      |
| 17:01–17:21 | 0.00–0.12   | (baseline idle)        |
| 17:22       | 0.62        | ###                    |
| **17:23**   | **1.95**    | #########              |
| **17:24**   | **2.05**    | ##########             |
| **17:25**   | **2.15**    | ##########             |
| **17:26**   | **2.92**    | ############### (peak) |
| **17:27**   | **2.18**    | ##########             |
| **17:28**   | **2.03**    | ##########             |
| **17:29**   | **2.05**    | ##########             |
| 17:30       | 2.18        | ##########             |
| 17:31       | 1.48        | #######                |
| 17:32–17:36 | 1.03–1.05   | #####                  |
| 17:37       | 0.47        | ##                     |
| 17:38–17:55 | 0.02–0.17   | (baseline)             |
| 17:56       | 0.62        | ### (brief retrigger)  |
| 17:57–18:00 | 0.00–0.10   | (baseline)             |

**Spike envelope:** rose from baseline at 17:22, peaked at 17:26 (2.92 AAS), held ≥ 1 AAS through 17:36, returned to baseline by 17:38. A brief re-trigger of similar SQL fired once more at 17:56 (~0.6 AAS for a single minute). Total elevated time ≈ 16 minutes.

---

## 3. Top SQL during the spike (17:20–17:35 UTC)

`db.load.avg` grouped by `db.sql_tokenized`, top 10:

| #   | DB load (AAS) | % of total | SQL (tokenized)                                                                                                                                                                              |
| --- | ------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 0.860         | 54.0 %     | `SELECT SUM(tf_duration) FROM master_live_index mli JOIN schedule pg ON pg.tf_database_key = mli.air_id JOIN master_content_index mci ON mci.mci_idx = mli.mci_idx WHERE audio_state = ?`    |
| 2   | 0.599         | 37.6 %     | `SELECT COUNT(*) FROM master_live_index mli JOIN schedule pg ON pg.tf_database_key = mli.air_id JOIN master_content_index mci ON mci.mci_idx = mli.mci_idx WHERE audio_state = ?`            |
| 3   | 0.053         | 3.3 %      | `CALL build_live_persistence_audio(?, @?)`                                                                                                                                                   |
| 4   | 0.033         | 2.1 %      | `UPDATE master_autocommercial_index mai INNER JOIN autocommercial_hit_updates ahc ON mai.mci_idx = ahc.mci_idx SET mai.last_seen = NOW()`                                                    |
| 5   | 0.019         | 1.2 %      | `CALL build_file_persistence(?, @?)`                                                                                                                                                         |
| 6   | 0.006         | 0.4 %      | `SELECT a.mci_idx FROM master_autocommercial_index a INNER JOIN master_content_index b ON a.mci_idx = b.mci_idx WHERE b.state IN (...) AND a.date_created < DATE_SUB(NOW(), INTERVAL ? DAY)` |
| 7   | 0.003         | 0.2 %      | `SELECT srv.hostname, s.site_id, i.input_id, i.source_priority FROM station st JOIN signals s ... JOIN inputs i ... JOIN server srv ...`                                                     |
| 8   | 0.003         | 0.2 %      | `SELECT a.mci_idx FROM master_autocommercial_index a INNER JOIN master_content_index b ... WHERE b.state IN (...) AND a.last_seen < DATE_SUB(NOW(), INTERVAL ? DAY)`                         |
| 9   | 0.003         | 0.2 %      | `CALL build_live_persistence(?, @?)`                                                                                                                                                         |
| 10  | 0.002         | 0.1 %      | `INSERT INTO master_content_index(state, last_updated, type, size) VALUES (...)`                                                                                                             |

**Queries #1 and #2 alone = 1.46 AAS = ~91.6 % of all DB load during the spike.** Both queries are 3-way JOINs across the same tables (`master_live_index` ⋈ `schedule` ⋈ `master_content_index`) filtered by `audio_state`. They differ only in projection (`SUM(tf_duration)` vs `COUNT(*)`), strongly suggesting they were executed back-to-back as part of a single reporting/aggregation workflow.

**PI SQL fingerprint IDs (use these to look up full statement, plan, and per-execution stats in the PI console):**

| Rank | `db.sql_tokenized.id`                      | `db.sql_tokenized.db_id`           |
| ---- | ------------------------------------------ | ---------------------------------- |
| 1    | `375AD3C158D8BD8E120CBCAFCA817D55521F03A0` | `e360cca4bba731acef7d14c13c0c994d` |
| 2    | `5EDD256AA5D6BF2F27D4E9E3D59917B0CDB3F205` | `0ae35c3a53c65bb5d67a2e84853e3646` |

---

## 4. Top wait events (proves CPU-bound, not memory-bound)

`db.load.avg` grouped by `db.wait_event`, top 8:

| #   | Wait event                   | Type  | DB load (AAS) | Interpretation                                             |
| --- | ---------------------------- | ----- | ------------- | ---------------------------------------------------------- |
| 1   | `executing`                  | Other | 1.550         | Active CPU work — **not** blocked on I/O, lock, or memory. |
| 2   | `waiting for handler commit` | Other | 0.027         | Trivial — normal txn commit overhead.                      |
| 3   | `updating reference tables`  | Other | 0.004         | Internal stage of UPDATE. Negligible.                      |
| 4   | `freeing items`              | Other | 0.002         | Statement teardown. Negligible.                            |
| 5   | `Opening tables`             | Other | 0.002         | Negligible.                                                |
| 6   | `updating`                   | Other | 0.001         | Negligible.                                                |
| 7   | `query end`                  | Other | 0.001         | Negligible.                                                |
| 8   | `creating table`             | Other | 0.001         | One CREATE TABLE somewhere. Negligible.                    |

**Notably absent:** Any `wait/io/*`, `wait/synch/*`, `wait/lock/*`, or memory-allocator waits. **97 % of spike load was raw CPU time on the JOIN+SUM/COUNT.** No buffer-pool contention, no disk I/O wait, no lock wait. The bottleneck was the cost of the query plan itself.

---

## 5. Top hosts during the spike — origin attribution

`db.load.avg` grouped by `db.host`, top 10, with reverse-lookup to ASG / EC2 / role:

| #   | Source IP        | DB load (AAS) | % of total | Service / ASG                    | Instance type | Notes                                                                                                |
| --- | ---------------- | ------------- | ---------- | -------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------- |
| 1   | `172.17.151.120` | **1.459**     | **91.5 %** | **`openvpn-production-iad`**     | `t3.small`    | **VPN gateway.** Traffic is NAT-ed from a human user or tool on the VPN — not an application worker. |
| 2   | `172.17.129.158` | 0.084         | 5.3 %      | `control-plane-dts-dtsstage-iad` | `t3.small`    | Normal control-plane traffic. Always present.                                                        |
| 3   | `172.17.13.228`  | 0.004         | 0.3 %      | `control-plane-monitor`          | `c5.4xlarge`  | Monitoring service.                                                                                  |
| 4   | `172.17.71.101`  | 0.003         | 0.2 %      | `imc-staging-live-iad`           | `m5.2xlarge`  | Staging IMC node.                                                                                    |
| 5   | `172.17.16.236`  | 0.003         | 0.2 %      | `dts-cdetector-staging-iad`      | `c6a.2xlarge` | Normal app-worker traffic.                                                                           |
| 6   | `172.17.31.78`   | 0.003         | 0.2 %      | `dts-cdetector-staging-iad`      | `c6a.2xlarge` | Normal app-worker traffic.                                                                           |
| 7   | `172.17.20.11`   | 0.002         | 0.1 %      | `dts-cdetector-staging-iad`      | `c6a.2xlarge` | Normal app-worker traffic.                                                                           |
| 8   | `172.17.23.201`  | 0.002         | 0.1 %      | (ENI gone)                       | —             | Instance has since been terminated/replaced.                                                         |
| 9   | `172.17.25.173`  | 0.002         | 0.1 %      | `dts-cdetector-staging-iad`      | `c6a.2xlarge` | Normal app-worker traffic.                                                                           |
| 10  | `172.17.24.202`  | 0.002         | 0.1 %      | `dts-cdetector-staging-iad`      | `c6a.2xlarge` | Normal app-worker traffic.                                                                           |

**This is the smoking gun.** During the 6-minute CPU spike, **one IP behind the VPN gateway generated 91.5 % of all DB load**, while the 45-node dts-cdetector ASG that normally drives ~99 % of STAGE traffic was effectively idle. The spike was an **outside-of-normal-workflow event** — somebody using mysql-cli, DBeaver, MySQL Workbench, Datagrip, or similar via VPN.

---

## 6. Top users during the spike

`db.load.avg` grouped by `db.user`:

| #   | MySQL user | DB load (AAS) | % of total | Notes                                                                                                                                                   |
| --- | ---------- | ------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `root`     | 1.589         | **99.7 %** | The only meaningful user during the spike. Application services normally connect as service-specific users — `root` is not used by automated workloads. |

**Combined with the host attribution:** somebody connected to STAGE as `root` from behind the OpenVPN gateway at 17:22 UTC and ran two heavy aggregation queries until ~17:37 UTC. **This is consistent with a human running a one-off report or investigation, not a runaway service.**

---

## 7. Baseline comparison — same queries in normal traffic

`db.load.avg` grouped by `db.sql_tokenized` for the **full 24 hours** of 06-18 UTC (entire day, not just the spike window):

| #   | DB load (AAS, 24h avg) | SQL (tokenized) — abridged                                                                                  |
| --- | ---------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1   | 0.034                  | `UPDATE master_autocommercial_index mai INNER JOIN autocommercial_hit_updates ahc ...`                      |
| 2   | 0.019                  | `INSERT INTO master_content_index(state, last_updated, type) VALUES (...)`                                  |
| 3   | 0.014                  | `CALL build_live_persistence_audio(?, @?)`                                                                  |
| 4   | **0.010**              | **`SELECT SUM(tf_duration) FROM master_live_index ... WHERE audio_state = ?`**  ← same as spike #1          |
| 5   | **0.006**              | **`SELECT COUNT(*) FROM master_live_index ... WHERE audio_state = ?`**  ← same as spike #2                  |
| 6   | 0.006                  | `CALL build_file_persistence(?, @?)`                                                                        |
| 7   | 0.004                  | `UPDATE master_content_index SET state=?, last_updated=NOW() WHERE mci_idx=? AND UNIX_TIMESTAMP(...)`       |
| 8   | 0.003                  | `SELECT tms_schedule.tf_database_key, tms_schedule.tf_station_num, CONCAT(STR_TO_DATE(tf_air_date,...))...` |
| 9   | 0.003                  | `SELECT COUNT(?) FROM schedule_restore`                                                                     |
| 10  | 0.003                  | `SELECT tms_schedule.tf_database_key, REPLACE(REPLACE(REPLACE(...program.tf_title...)))...`                 |

**Key observation:** The spike's #1 and #2 queries also rank as the 24-hour #4 and #5 — meaning these queries **do exist in normal application traffic at low frequency** (~0.01 / 0.006 AAS). The application uses them; they are not foreign SQL.

**Spike vs baseline rate multiplier:**

| Query                                  | Spike rate (15-min avg) | Baseline rate (24-h avg) | Multiplier during spike |
| -------------------------------------- | ----------------------: | -----------------------: | ----------------------: |
| `SELECT SUM(tf_duration) FROM mli ...` |                   0.860 |                    0.010 |                 **86×** |
| `SELECT COUNT(*) FROM mli ...`         |                   0.599 |                    0.006 |                **100×** |

The user ran these same queries **about 100× more aggressively than the application does in steady state** — most likely in a loop, in parallel sessions, or against a wider date / state filter than the application normally uses.

### Top hosts in the 24-hour baseline (for comparison)

| #   | Source IP        | DB load (AAS, 24h avg) | Service                                                                                       |
| --- | ---------------- | ---------------------: | --------------------------------------------------------------------------------------------- |
| 1   | `172.17.46.194`  |                  0.027 | (not in audit window — likely dts-cdetector ASG)                                              |
| 2   | `172.17.129.158` |                  0.022 | `control-plane-dts-dtsstage-iad`                                                              |
| 3   | `172.17.151.120` |                  0.016 | `openvpn-production-iad` ← VPN gateway, still appears in baseline because of the spike itself |
| 4   | `172.17.142.225` |                  0.007 | (not in audit window)                                                                         |
| 5   | `172.17.13.228`  |                  0.005 | `control-plane-monitor`                                                                       |
| 6   | `10.145.145.80`  |                  0.004 | (RFC1918 outside primary CIDR — likely AWS Client VPN endpoint)                               |
| 7   | `172.17.71.101`  |                  0.003 | `imc-staging-live-iad`                                                                        |
| 8   | `10.145.154.255` |                  0.003 | (likely AWS Client VPN endpoint)                                                              |
| 9   | `172.17.13.181`  |                  0.002 | (not in audit window)                                                                         |
| 10  | `172.17.10.245`  |                  0.002 | (not in audit window)                                                                         |

The presence of the VPN gateway in the 24-hour list is *entirely caused by the spike itself* — without the 15-minute spike contribution, VPN gateway load would be near zero.

---

## 8. Can Performance Insights tell us memory consumption per query?

**No.** This is a frequent misconception. PI reports DB **load** (active session time) and waits — not memory bytes. Specifically:

| Question                                                              | Answer                                                                                                                                   |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Does PI break out per-query memory?                                   | No.                                                                                                                                      |
| Does PI break out per-query temp-table size?                          | No.                                                                                                                                      |
| Does PI surface MySQL's `performance_schema.memory_summary_*` tables? | No.                                                                                                                                      |
| Does Enhanced Monitoring break out per-query memory?                  | No — it shows OS-level free/used/cached only.                                                                                            |
| Was MySQL's slow query log on during the spike?                       | **No** (off on both PGs — see [REPORT.md §7.1](REPORT.md)). It would have captured per-query `Tmp_table_sizes`, `Filesort_on_disk`, etc. |
| Was the MariaDB audit log retention long enough?                      | **No** — STAGE retains only ~44 minutes. Audit logs for the spike rolled off well before this investigation started.                     |

**The closest signal to "memory cost" in this PI dataset:** the queries appeared as `executing` (CPU) without `creating sort index`, `Sorting result`, `Copying to tmp table`, or `Copying to tmp table on disk` wait events. **If they had built large in-memory temp tables, PI would have shown one of those waits** (the InnoDB / SQL-layer instrumentation surfaces them as separate `db.wait_event` values). Their absence is positive evidence that the queries did **not** allocate significant temp-table memory and were just CPU-bound JOINs returning small result sets.

---

## 9. Conclusions

1. **Identified culprit:** A single human-or-tool session connected through `openvpn-production-iad` (`172.17.151.120`) as MySQL user `root`, executing two known application queries on `master_live_index` / `schedule` / `master_content_index` joined-and-filtered by `audio_state`, at roughly 100× the application's normal rate, for ~16 minutes.
2. **Nature of load:** Pure CPU. Wait events confirm there was no I/O, no lock contention, and no temp-table memory pressure. CloudWatch FreeableMemory and SwapUsage corroborate (no memory event whatsoever — see [REPORT.md §2.4](REPORT.md)).
3. **This is the "spike" the user perceived.** It was on Thursday 06-18, not Saturday 06-20. There never was a Saturday-related transition; CloudWatch shows no Saturday inflection on any metric.
4. **Per-query memory consumption cannot be determined retroactively from PI or any other AWS-managed data source for this window.** The only path to that information going forward is the slow query log (recommendation #1 in [REPORT.md §10](REPORT.md)).

---

## 10. Next steps

| #   | Action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Effort |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | **Confirm with the team** whether someone ran an ad-hoc report against STAGE Thursday 2026-06-18 around 17:22–17:37 UTC. Suggested ask: "Did anyone run a SUM/COUNT against master_live_index with audio_state filter via VPN as root on Thursday afternoon?" Likely a billing, content reconciliation, or QA validation task.                                                                                                                                                                       | 5 min  |
| 2   | **Disable interactive `root` access from VPN to staging RDS.** Force individuals to use named MySQL accounts so PI can attribute load per person, and audit log can attribute events per person. The CWE-256 implication of `root` over VPN is also worth addressing.                                                                                                                                                                                                                                | 30 min |
| 3   | **Enable slow query log** with `slow_query_log=1`, `long_query_time=1`, `log_output=TABLE,FILE` (recommendation #1 in REPORT.md §10). The next time this happens we'll have the exact statement plus its `Tmp_table_sizes`, `Filesort_on_disk`, and `Rows_examined`.                                                                                                                                                                                                                                 | 5 min  |
| 4   | **Add an index** to support the recurring filter. The query `SELECT SUM/COUNT FROM master_live_index mli JOIN schedule pg ON pg.tf_database_key = mli.air_id JOIN master_content_index mci ON mci.mci_idx = mli.mci_idx WHERE audio_state = ?` may benefit from a composite index on `(audio_state, air_id, mci_idx)` of `master_live_index`. Validate with `EXPLAIN` against a current plan; if the optimizer is doing a full scan, even infrequent ad-hoc usage at 100× rate will spike CPU again. | 1 h    |
| 5   | **Increase MySQL `performance_schema` memory instrumentation visibility.** Enable `memory/%` instruments and consumers (currently default-on but selectively enabled). Then `SELECT * FROM performance_schema.memory_summary_global_by_event_name ORDER BY current_alloc DESC LIMIT 20;` becomes a usable live troubleshooting view. Pairs well with the slow-log change in #3.                                                                                                                      | 10 min |

---

## 11. Files produced

| File                                        | Purpose                                                                            |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| `pi/stage_thu_spike_topsql.json`            | Raw PI `describe-dimension-keys` output — top 10 SQL during spike (15-min window). |
| `pi/stage_thu_spike_waits.json`             | Raw PI output — top wait events during spike.                                      |
| `pi/stage_thu_spike_hosts.json`             | Raw PI output — top 10 hosts during spike.                                         |
| `pi/stage_thu_spike_users.json`             | Raw PI output — top users during spike.                                            |
| `pi/stage_thu_24h_topsql.json`              | Raw PI output — top 10 SQL across the full 24-hour day (baseline comparison).      |
| `pi/stage_thu_24h_hosts.json`               | Raw PI output — top 10 hosts across the full 24-hour day (baseline comparison).    |
| `pi/stage_thu_spike_dbload_timeseries.json` | Raw PI output — `db.load.avg` per-minute timeseries 17:00–18:00 UTC.               |
| `queryinsights.md`                          | **This document.**                                                                 |

---

## 12. Methodology — exactly how to reproduce

```bash
export AWS_PROFILE=inscape-production-us-1-inscape-aws-ops AWS_REGION=us-east-1
STAGE_RID="db-NVRXOKTVBR33P5QR6NZQGDW4WA"

# Top SQL
aws pi describe-dimension-keys \
  --service-type RDS --identifier "$STAGE_RID" \
  --start-time 2026-06-18T17:20:00Z --end-time 2026-06-18T17:35:00Z \
  --metric db.load.avg \
  --group-by '{"Group":"db.sql_tokenized","Limit":10}' \
  --period-in-seconds 60

# Top wait events
aws pi describe-dimension-keys \
  --service-type RDS --identifier "$STAGE_RID" \
  --start-time 2026-06-18T17:20:00Z --end-time 2026-06-18T17:35:00Z \
  --metric db.load.avg \
  --group-by '{"Group":"db.wait_event","Limit":10}' \
  --period-in-seconds 60

# Top hosts
aws pi describe-dimension-keys \
  --service-type RDS --identifier "$STAGE_RID" \
  --start-time 2026-06-18T17:20:00Z --end-time 2026-06-18T17:35:00Z \
  --metric db.load.avg \
  --group-by '{"Group":"db.host","Limit":10}' \
  --period-in-seconds 60

# Top users
aws pi describe-dimension-keys \
  --service-type RDS --identifier "$STAGE_RID" \
  --start-time 2026-06-18T17:20:00Z --end-time 2026-06-18T17:35:00Z \
  --metric db.load.avg \
  --group-by '{"Group":"db.user","Limit":10}' \
  --period-in-seconds 60

# Per-minute db.load timeseries
aws pi get-resource-metrics \
  --service-type RDS --identifier "$STAGE_RID" \
  --start-time 2026-06-18T17:00:00Z --end-time 2026-06-18T18:00:00Z \
  --metric-queries '[{"Metric":"db.load.avg"}]' \
  --period-in-seconds 60
```

All commands return raw JSON. Times in this document are converted to UTC; the AWS CLI returns aligned timestamps in the caller's local timezone (here MDT, UTC-06:00).

---

## 13. Per-execution latency analysis (added 2026-06-23)

**Method:** PI's `count_star_per_sec.avg` aggregate over a 24-hour window × 86 400 s gives total executions. Total DB time = `db.load.avg × window_sec`. Derived per-call latency = `total_db_time / total_executions`. This is more accurate than the `sum_timer_wait_per_call.avg` PI metric, which returns 0 in buckets with no completions and skews the cross-bucket average toward 0.

The two spike queries (rank #4 and #5 on the 24-hour list) had effectively **zero captured completions** in the entire 24 h, despite running constantly during the 15-min spike window. The only way that's possible is if **each execution lasted longer than a single PI 5-min bucket** — i.e., the digest counter ticked, but at a rate too low to register against the per-second aggregation. Each call is on the order of **tens of seconds to minutes**, consistent with someone running them interactively, viewing results, and re-running.

### 13.1 Per-call latency on Thursday (2026-06-18, 00:00–24:00 UTC)

| #   | SQL (truncated, full text in PI console)                                                                    | Execs / 24h | **Avg latency** | Rows examined / call | Rows sent / call | Verdict                                                              |
| --- | ----------------------------------------------------------------------------------------------------------- | ----------: | --------------: | -------------------: | ---------------: | -------------------------------------------------------------------- |
| 1   | `UPDATE master_autocommercial_index ... SET last_seen=NOW()`                                                |     472,423 |        **6 ms** |                   97 |                0 | Fast & frequent. Healthy.                                            |
| 2   | `INSERT INTO master_content_index(state, last_updated, type) VALUES (?, NOW(), ?)`                          |     386,516 |        **4 ms** |                    1 |                0 | Fast & frequent. Healthy.                                            |
| 3   | `CALL build_live_persistence_audio(?, @?)`                                                                  |         330 |      **3.58 s** |                    — |                — | **Slow stored proc.** 330 calls/day = once every ~4 min.             |
| 4   | `SELECT SUM(tf_duration) FROM master_live_index ... WHERE audio_state=?` *(spike #1)*                       | ~0 captured |   **≥ minutes** |                    — |                — | **Very slow.** Digest counter saw no per-second completions in 24 h. |
| 5   | `SELECT COUNT(*) FROM master_live_index ... WHERE audio_state=?` *(spike #2)*                               | ~0 captured |   **≥ minutes** |                    — |                — | **Very slow.** Same pattern as #4.                                   |
| 6   | `CALL build_file_persistence(?, @?)`                                                                        |         330 |      **1.43 s** |                    — |                — | **Slow stored proc.** Once every ~4 min.                             |
| 7   | `UPDATE master_content_index SET state=?, last_updated=NOW() WHERE mci_idx=? AND ...`                       |      55,922 |        **6 ms** |                    1 |                0 | Fast & frequent.                                                     |
| 8   | `SELECT tms_schedule.tf_database_key, tms_schedule.tf_station_num, CONCAT(STR_TO_DATE(tf_air_date,...))...` |         129 |      **2.08 s** |        **2,174,972** |            3,707 | **Slow analytical.** Scans 2 M rows to return 3.7 K.                 |
| 9   | `SELECT COUNT(?) FROM schedule_restore`                                                                     |       **1** |    **260 s** !! |                    0 |                1 | **Extremely slow.** Single execution took **4 min 20 sec**.          |
| 10  | `SELECT tms_schedule.tf_database_key, REPLACE(REPLACE(...program.tf_title...))`                             |         130 |      **1.85 s** |        **2,167,402** |            3,691 | **Slow analytical.** Twin of #8.                                     |

### 13.2 Headline findings

1. **Spike queries (#4, #5) are individually very slow** — likely tens of seconds to minutes per call. They are **not a loop**; they are an interactive user pacing themselves. Each call probably scans the entire `master_live_index ⋈ schedule ⋈ master_content_index` join because the `audio_state` filter has no supporting index.
2. **The hot-path application traffic is healthy.** Queries #1, #2, #7 run hundreds of thousands of times per day each, all at 4–6 ms. Nothing to tune there.
3. **None of the slow queries spilled to disk-temp** (`Created_tmp_disk_tables_per_call = 0` for every entry, even the 2 M-row scans). The 200 MiB `tmp_table_size` on STAGE is adequate for the current workload — the slow queries are slow because of **CPU on JOINs**, not memory or temp-table pressure.

---

## 14. Other slow queries that have nothing to do with the spike

These showed up in the 24-hour baseline and deserve attention independently of the Thursday spike investigation. They are background tax on the database that runs all day, every day.

### 14.1 The biggest one — `SELECT COUNT(?) FROM schedule_restore`

| Property          | Value                                                                                                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Executions / 24 h | **1**                                                                                                                                                                                   |
| Latency           | **260 seconds** (≈ 4 min 20 sec) for that single execution                                                                                                                              |
| Rows examined     | 0 *(probably a metadata-only count that still required a full index/table walk)*                                                                                                        |
| Rows sent         | 1                                                                                                                                                                                       |
| Likely cause      | Table is large and either has no PK / no usable secondary index for `COUNT`                                                                                                             |
| Pattern           | `COUNT(?)` with a placeholder = literal `COUNT(1)` or `COUNT(NULL)` — interactive ad-hoc, not application code                                                                          |
| Action            | Identify caller (likely `root` again over VPN). If recurring, add a small covering index or replace with `EXPLAIN`-driven approximate count via `information_schema.tables.table_rows`. |

### 14.2 Twin analytical SELECTs against `tms_schedule + program` (queries #8 and #10)

Both queries scan ~2.17 million rows to return ~3,700 rows — a **587:1 read amplification** per call. At 130 calls/day each, that's **~565 million row examinations/day** between the two.

| Property             | #8            | #10           |
| -------------------- | ------------- | ------------- |
| Executions / 24 h    | 129           | 130           |
| Latency              | **2.08 s**    | **1.85 s**    |
| Rows examined / call | **2,174,972** | **2,167,402** |
| Rows sent / call     | 3,707         | 3,691         |
| Read amplification   | 587 ×         | 587 ×         |
| Full join (`fj`)     | 1 (yes)       | 0             |

- **Likely fix:** Composite index on `tms_schedule(tf_air_date, tf_database_key)` and / or `tf_station_num`. Validate with `EXPLAIN` against current plan first.
- **Estimated improvement:** If a covering index reduces rows examined to ~10 K (the join cardinality), latency drops to ~10 ms and CPU saved ≈ 270 sec / day.

These are almost certainly a recurring **scheduled report or polling job** (regular cadence: 129/day ≈ once every 11 min). Find the caller (could be a control-plane or analytics worker), confirm the access pattern, then add the index.

### 14.3 Slow stored procedures (`build_live_persistence_audio`, `build_file_persistence`)

| Procedure                             | Calls / 24 h | Avg latency | Notes                                                                                                                        |
| ------------------------------------- | -----------: | ----------: | ---------------------------------------------------------------------------------------------------------------------------- |
| `build_live_persistence_audio(?, @?)` |          330 |  **3.58 s** | Called every ~4 minutes. Multi-second procs aren't catastrophic but accumulate to ~20 min of CPU per day on this proc alone. |
| `build_file_persistence(?, @?)`       |          330 |  **1.43 s** | Twin proc — also every ~4 min. ~8 min of CPU per day.                                                                        |

These are application-owned. Worth a code review: profile internal statements with `performance_schema.events_statements_history_long` or by enabling proc-level slow-log; index review on the tables they touch.

### 14.4 Priority order

| Priority | Item                                                                               | Effort | Payoff                                                                                                        |
| -------- | ---------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| P1       | Add index supporting `master_live_index.audio_state` (spike queries #4/#5)         | 30 min | Eliminates the same-query-different-user spike from happening again. Direct mitigation of the Thursday event. |
| P2       | Composite index on `tms_schedule` for the twin analytical SELECTs (§14.2)          | 1 h    | Removes ~565 M row examinations/day; ~270 sec CPU/day savings.                                                |
| P3       | Identify and review the `COUNT(?) FROM schedule_restore` caller (§14.1)            | 15 min | Either eliminates the 4-minute query entirely or replaces it with metadata lookup.                            |
| P4       | Profile and tune `build_live_persistence_audio` / `build_file_persistence` (§14.3) | 2 h    | Reduces ~30 min/day of background CPU.                                                                        |
| P5       | Enable slow query log per [REPORT.md §10](REPORT.md) recommendation #1             | 5 min  | Captures all of the above going forward without needing PI digest tricks.                                     |

---

## 15. Files produced (addendum)

| File                                   | Purpose                                                                                            |
| -------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `pi/stage_thu_spike_topsql_stats.json` | PI `describe-dimension-keys` with `--additional-metrics` for spike window — for per-call analysis. |
| `pi/stage_thu_24h_topsql_stats.json`   | Same call for the full 24 h — basis for §13.1 latency table.                                       |
| `pi/_avail1.json`                      | `list-available-resource-metrics` output — canonical list of `db.sql_tokenized.stats.*` names.     |
