# Executive Summary — IMS/Account Aurora PostgreSQL Incident, 2026-09-11

**Service:** IMS/Account platform database (`ims-account-aurora-us-west-2-cluster`, AWS us-west-2, account `iam-account-prod` / 889059331444).
**Incident window:** Friday 2026-09-11, 4:38 PM – 6:20 PM MT.
**Author date:** 2026-09-15.
**Full technical detail:** [`report.md`](./report.md) · [`rds-proxy-findings.md`](./rds-proxy-findings.md).

---

## What happened

At 4:38 PM MT on Friday 9/11, the production Aurora PostgreSQL cluster serving the IMS/Account platform saturated its CPU (99.8 %). Concurrent database sessions on the writer climbed from a normal baseline of ~1,660 to a peak of 4,504 — roughly **2.7× baseline**, and about 90 % of the instance's 5,000-connection ceiling. Content Services and other applications backed by this database began failing. Two on-call pages fired (5:00 PM and 5:30 PM). Content Services manually severed its database connections at 6:10 PM. At 6:15 PM, AWS's automated database health monitor performed an unassisted failover to a healthy replica; the failover itself took 21 seconds. All services were healthy again by 6:20 PM.

## Business impact

Approximately **1 hour 40 minutes** of degraded-to-unavailable IMS/Account database service during business hours, spanning multiple downstream applications and requiring on-call engagement from both the DBA/DRE team and Content Services. Recovery was automated by AWS, not by manual intervention.

## Root cause

Two problems compounded to produce the outage:

1. **The writer's CPU was saturated by workload, and observability was not in place to identify which workload.** Peak CPU was 99.8 % with commit latency spiking ~60× baseline while concurrent sessions climbed to 4,504 on an instance whose configured ceiling is 5,000. Once CPU was pinned, in-flight queries stopped completing, applications reconnected in a loop, and every additional session added to the load. We cannot pinpoint the specific query or scheduled job that triggered the initial spike, because three basic observability features were not enabled on this database: Performance Insights was disabled, the AWS default parameter group (which cannot log slow queries or connection metadata) was in use, and PostgreSQL logs for the incident window had already aged out before the investigation began.
2. **The connection pooler that was supposed to shield the cluster is being bypassed, and its own pool is sized far below the DB's real capacity.** An RDS Proxy (`account-db-prod-proxy-us-west-2`) was deployed in June 2026 specifically for this cluster, but roughly **94 % of application traffic still connects to the database directly**, ignoring the proxy. The proxy carried only 261 of the 4,504 peak sessions. The 6 % of traffic that did use the proxy also suffered — the proxy's own pool ceiling (`MaxDatabaseConnectionsAllowed` = 261) is roughly 5 % of the ~4,500-connection ceiling that the database's `max_connections` (5,000) and the proxy's `MaxConnectionsPercent` (90 %) should permit, so the pool exhausted and returned 5-second connection-borrow-timeout errors to those clients for over an hour. The most likely cause of the 261 cap is a per-role `CONNECTION LIMIT` on the proxy's auth user (`ims_acct_db_user`), which needs confirmation on the DB itself.

## Why the outage wasn't caught earlier

There were no CloudWatch alarms on the database or the RDS Proxy for CPU, connection count, or connection-borrow latency. Both problems (proxy pool exhaustion and database CPU saturation) were observable in real time and would have paged the on-call ~20 minutes before the first human page had alarms existed.

## What we are doing about it

**Immediate — this week (no downtime, no cost):**

- Enable Performance Insights on the cluster.
- Move the cluster off the AWS default parameter group and turn on slow-query, connection, and disconnection logging.
- Ship database logs to CloudWatch for permanent retention.
- Add CloudWatch alarms on both the database (CPU, connections, commit latency) and the RDS Proxy (borrow latency, pool utilization).
- Confirm on the writer directly why the proxy's `MaxDatabaseConnectionsAllowed` is capped at 261 — check `pg_roles.rolconnlimit` on the proxy's auth user, and reconcile against the proxy target group's `MaxConnectionsPercent`. Remove or raise the cap so the proxy pool can grow to match the DB.

**Near-term — this sprint (planned change window):**

- Once Performance Insights is live and workload is characterized, identify and remediate the CPU-saturating query or job class from 9/11.
- Right-size the RDS Proxy pool to match the DB's real capacity (target 2,000–3,000 pooled connections, not 261) after removing whatever cap is currently pinning it.
- Investigate the `max_wal_senders` configuration warning that surfaced during the failover.

**Structural — next 1–2 sprints (cross-team coordination):**

- Enforce RDS Proxy usage at the network layer by removing direct database access from application security groups. This is the single change that would have prevented the incident.
- Inventory every service currently bypassing the proxy, and either migrate it to the proxy or document it as a permitted exception (BI tools, schema migrations, DR paths, etc.).
- Codify all of the above in Terraform so the fixes cannot silently drift.

## Residual risk

Until the structural work lands, **the same failure mode can recur at any time**. The failover recovered service, but nothing about the database configuration or the connection pattern has changed. Every recommendation above is owner-clear, requires no vendor coordination, and has been costed against known-safe change windows.

## Owners

- **DBA/DRE (SDO):** database configuration, parameter groups, Performance Insights, alarms, RDS Proxy tuning, network-level enforcement of proxy usage.
- **Application teams (Content Services, IMS/Account, and any other consumer of this cluster):** repointing connection strings to the proxy endpoint, and validating that their driver, TLS, and authentication settings are compatible with the proxy.

## Timeline

| Time (MT)     | Time (UTC)          | Event                                                                           |
|---------------|---------------------|---------------------------------------------------------------------------------|
| 4:38 PM Fri   | 22:38 Fri           | Database CPU + connection spike begins on the writer                            |
| 5:00 PM Fri   | 23:00 Fri           | First on-call page                                                              |
| 5:30 PM Fri   | 23:30 Fri           | Second on-call page                                                             |
| 6:10 PM Fri   | 00:10 Sat           | Content Services manually severs its database connections                       |
| **6:15 PM Fri** | **00:15 Sat**     | **AWS automatically fails the database over to a healthy replica (21 seconds)** |
| 6:20 PM Fri   | 00:20 Sat           | All services back to healthy baseline                                           |
