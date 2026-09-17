# RDS Proxy Investigation — ims-account-aurora-us-west-2-cluster

**Incident:** 2026-09-11 22:38 UTC → 2026-09-12 00:15 UTC connection storm + CPU saturation + RDS-initiated failover on `ims-account-aurora-us-west-2-cluster`.
**Account:** 889059331444 (`iam-account-prod`, profile `IkonAWSAdministratorAccess`).
**Region:** us-west-2.
**Scope of this document:** did the RDS Proxy in front of this cluster have connection issues, why is most traffic bypassing it, and what to do next.
**Companion report:** [`report.md`](./report.md) (full incident forensics — Aurora metrics, failover timeline, PI/log gaps).
**Author date:** 2026-09-15.

---

## TL;DR

1. **Yes, the RDS Proxy had connection issues.** `account-db-prod-proxy-us-west-2` sat pinned at its DB pool ceiling (261 connections) for ~1 h 40 m, with `DatabaseConnectionsBorrowLatency` averaging 3.1 s and peaking at 7.13 s — well above its 5 s `ConnectionBorrowTimeout`. Every borrow above 5 s returned a client-visible error, which drove a 3,400-new-sessions/minute reconnect storm.
2. **The proxy is not what caused the outage. Direct-to-cluster traffic did.** The Aurora writer saw 4,504 concurrent DB sessions at peak; only 261 came through the proxy. **~4,243 sessions (≈ 94 %) bypassed the proxy entirely** and hit the cluster/writer endpoint directly — that's what filled `max_connections` and pinned CPU at 99.8 %.
3. **The proxy is doing its job. The environment is not.** Underlying `max_connections` is only ~290 (Aurora default), the proxy secret only covers one credential path, and the cluster's security group ingress is wide open, so most services never onboarded to the proxy.
4. **Highest-impact fix:** raise DB `max_connections` on a custom parameter group, force apps through the proxy via SG-level enforcement, and add the proxy alarms in §7. Everything else is secondary.

---

## 1. Proxy under investigation

| Field                                       | Value                                                                                           |
|---------------------------------------------|-------------------------------------------------------------------------------------------------|
| `DBProxyName`                               | `account-db-prod-proxy-us-west-2`                                                               |
| `DBProxyArn`                                | `arn:aws:rds:us-west-2:889059331444:db-proxy:prx-058100dfc385694a2`                             |
| `Endpoint`                                  | `account-db-prod-proxy-us-west-2.proxy-c38c4oymc9wd.us-west-2.rds.amazonaws.com`                 |
| `EngineFamily`                              | POSTGRESQL                                                                                      |
| `TrackedClusterId`                          | `ims-account-aurora-us-west-2-cluster` (the incident cluster)                                   |
| `VpcId`                                     | `vpc-0ed87385cbe527b86`                                                                         |
| `VpcSubnetIds`                              | `subnet-080f1b123f5f645ef`, `subnet-0569189f9ca9def68`                                          |
| `VpcSecurityGroupIds`                       | `sg-0c01aa6afc4213e65`                                                                          |
| `Auth[0].SecretArn`                         | `arn:aws:secretsmanager:us-west-2:889059331444:secret:account-db-prod-aurora-db-credentials-e39b1ec4be574334-DsPXu6` |
| `Auth[0].IAMAuth`                           | DISABLED                                                                                        |
| `Auth[0].ClientPasswordAuthType`            | POSTGRES_SCRAM_SHA_256                                                                          |
| `RoleArn`                                   | `arn:aws:iam::889059331444:role/account-db-prod-rds-proxy-role`                                 |
| Target group `MaxConnectionsPercent`        | **90 %**                                                                                        |
| Target group `MaxIdleConnectionsPercent`    | 75 %                                                                                            |
| Target group `ConnectionBorrowTimeout`      | **5 seconds**                                                                                   |
| Target group `SessionPinningFilters`        | (none)                                                                                          |
| Observed `MaxDatabaseConnectionsAllowed`    | **261**  → implies underlying `max_connections` ≈ 290                                          |
| Proxy created                               | 2026-06-02 (~3 months before incident)                                                          |

### Registered targets

| RdsResourceId                              | Type          | Role       | TargetHealth |
|--------------------------------------------|---------------|------------|--------------|
| `ims-account-aurora-us-west-2-cluster`     | TRACKED_CLUSTER | —        | —            |
| `ims-account-aurora-us-west-2-cluster-0`   | RDS_INSTANCE  | READ_ONLY  | AVAILABLE    |
| `ims-account-aurora-us-west-2-cluster-1`   | RDS_INSTANCE  | READ_ONLY  | AVAILABLE    |
| `ims-account-aurora-us-west-2-cluster-2`   | RDS_INSTANCE  | READ_WRITE | AVAILABLE    |

Roles above reflect current topology (post-failover). During the incident cluster-0 was READ_WRITE and cluster-2 was READ_ONLY.

---

## 2. Proxy metric summary (2026-09-11 22:00 UTC → 2026-09-12 01:00 UTC, 1-min)

Raw JSON: [`rds-proxy/metrics/`](./rds-proxy/metrics/). CSV: [`rds-proxy/proxy-metrics-1min.csv`](./rds-proxy/proxy-metrics-1min.csv). Detailed anchor snapshots: [`rds-proxy/proxy-metrics-summary.md`](./rds-proxy/proxy-metrics-summary.md).

| Metric                                    | Unit  | Peak                        | Avg                        | Interpretation                                                    |
|-------------------------------------------|-------|-----------------------------|----------------------------|-------------------------------------------------------------------|
| ClientConnections                         | count | **908**                     | 158                        | Active client sessions on proxy (~60× pre-spike)                  |
| ClientConnectionsReceived                 | /min  | **3,417**                   | 156                        | Client reconnect storm                                            |
| ClientConnectionsClosed                   | /min  | **3,438**                   | 144                        | Matches Received → connect/close churn                            |
| ClientConnectionsSetupSucceeded           | /min  | 3,370                       | 155                        | Almost all setups completed                                       |
| ClientConnectionsSetupFailedAuth          | count | *no data*                   | *no data*                  | Not published → 0 auth failures in window                         |
| DatabaseConnections                       | count | **261**                     | 52                         | Pinned at proxy ceiling for hours                                 |
| DatabaseConnectionsCurrentlyBorrowed      | count | 261                         | 22                         | All 261 in use for extended periods                               |
| DatabaseConnectionsCurrentlySessionPinned | count | *no data*                   | *no data*                  | 0 pinning — pool is functioning as designed                       |
| DatabaseConnectionsBorrowLatency          | μs    | **7,131,550 (7.13 s)**      | **367,586 (368 ms)**       | Above the 5 s `ConnectionBorrowTimeout` ceiling                   |
| DatabaseConnectionRequests                | /min  | 1,479                       | 285                        | Client requests for a pool connection                             |
| MaxDatabaseConnectionsAllowed             | count | 261                         | 261                        | Static during window                                              |
| QueryDatabaseResponseLatency              | μs    | 16,379,784 (**16.4 s**)     | 3,255,794 (3.26 s)         | Sparse (3 samples) — queries were also slow                       |
| QueryRequests                             | /min  | 215                         | 54                         | Sparse                                                            |

### Timeline mapped to incident anchors

| UTC   | ClientConns avg / max | DBConns avg / max (of 261) | BorrowLatency avg / max | Interpretation                                                        |
|-------|-----------------------|----------------------------|-------------------------|-----------------------------------------------------------------------|
| 22:35 | 15 / 28               | 32 / 117                   | 99 μs / 1.4 ms          | Normal.                                                               |
| 22:38 | 16 / 28               | 32 / 117                   | 96 μs / 0.9 ms          | Aurora writer CPU spike started — proxy still calm.                   |
| 23:00 | 136 / 142             | 87 / **261**               | **239 ms / 1.15 s**     | Pool hit ceiling. Borrow latency up 3 orders of magnitude.            |
| 23:30 | 96 / 103              | 87 / 261                   | 109 ms / 747 ms         | Still queueing hard.                                                  |
| 00:10 | 274 / 465             | 55 / 261                   | **3.04 s / 5.37 s**     | **Above 5 s ConnectionBorrowTimeout** — clients getting errors.       |
| 00:14 | 302 / 449             | 37 / 261                   | **3.10 s / 5.28 s**     | Same. Content Services already disconnected — this is retry storm.    |
| 00:15 | 125 / 155             | 35 / 149                   | 641 ms / 4.92 s         | Failover completed → borrow queue draining.                           |
| 00:20 | 92 / 114              | 35 / 149                   | 78 μs / 2 ms            | Recovered to baseline.                                                |

**Interpretation.** Peak 7.13 s borrow latency and multi-second averages while `DatabaseConnections` sat pinned at 261 means the proxy's 5-second `ConnectionBorrowTimeout` was firing continuously. Every such timeout is an application-visible error (typically surfaces as `error: timed out waiting to acquire a database connection` or an equivalent driver-level exception). The 3,400 new-sessions/min churn is consistent with clients retrying those errors and the retries piling on.

**What the proxy metrics do *not* show.** No auth failures. No session pinning (proxy multiplexing worked correctly). This was pool exhaustion driven by slow DB, not a proxy misconfiguration for the SQL pattern.

---

## 3. The bigger problem — most traffic bypasses the proxy

| Signal                                                          | Value              |
|-----------------------------------------------------------------|--------------------|
| Aurora writer peak concurrent DB sessions (from `report.md`)    | **4,504**          |
| Proxy peak DB pool                                              | **261**            |
| Estimated direct-to-cluster connections                         | **≈ 4,243 (~94 %)** |

The proxy could not defend the cluster because most of the fleet doesn't route through it. Those direct connections filled `max_connections` and drove writer CPU to 99.8 %. Fixing the proxy pool sizing alone will not prevent recurrence — bypass is the actual failure mode.

---

## 4. Why applications bypass the proxy (ordered by likelihood in this environment)

Proxy created 2026-06-02, only 3 months before the incident. That framing alone makes reason #1 by far the dominant one.

1. **Connection strings never got updated when the proxy was added.** Any service deployed before 2026-06-02 that put the cluster writer/reader endpoint in Secrets Manager, a K8s ConfigMap, a Helm values file, an ECS task-def, or a Terraform module output kept using it. Fleet-wide rewiring rarely happens without a forcing function.
2. **Proxy's Secrets Manager secret is different from what apps read.** The proxy auths against exactly one secret (`account-db-prod-aurora-db-credentials-e39b1ec4be574334-DsPXu6`). Apps reading any other secret (per-app secrets, the cluster's original master secret, IAM-based creds) physically cannot authenticate through the proxy — even if they hit the endpoint.
3. **SCRAM-SHA-256 enforcement.** Proxy is `ClientPasswordAuthType: POSTGRES_SCRAM_SHA_256`. Drivers with weak SCRAM support (libpq < 10, node-postgres < 8.x, older JDBC, older Go `pq`, ancient `psycopg2`) fail the handshake — devs fall back to direct because "it works."
4. **TLS required through the proxy.** Any DSN with `sslmode=disable` / `ssl: false` / missing TLS parameters fails against the proxy and succeeds direct (Aurora Postgres doesn't force TLS by default).
5. **Postgres features that don't work well through the proxy.** `LISTEN`/`NOTIFY` (not supported at all), `WITH HOLD` cursors, session-level GUCs (`SET`), out-of-transaction `PREPARE`, temp tables held across statements, advisory locks. Devs hit one, get a pin storm or an error, route around.
6. **VPC / SG reachability.** Proxy sits behind `sg-0c01aa6afc4213e65` in only two subnets. Apps in other subnets/AZs, in different accounts via peering, or on SGs never allowed onto the proxy SG's ingress cannot reach the proxy — but they can reach the cluster endpoints because the Aurora SG has broader allow rules. The fact that 4,243 direct connections worked proves this asymmetry.
7. **Cross-region / us-east-1 workloads.** Only one proxy exists (us-west-2). Any us-east-1-hosted service that writes cross-region — including any DR failback path — talks to the writer endpoint direct. Global-cluster failover makes this permanent for the flipped region.
8. **Managed services and tooling that don't route through a proxy well or at all.** Schema-migration tools (Liquibase, Flyway, sqitch, Dataform, dbt), AWS Glue, AWS DMS, Athena Federated Query, BI tools (Tableau, Looker, Metabase, Grafana Postgres datasource), pg_dump / pg_restore, analyst ad-hoc — these virtually always point at the cluster endpoint in pipeline config.
9. **App-side connection pooler already in place.** Services already running PgBouncer sidecars or library-level pools (HikariCP, pgxpool, node-postgres pool) sometimes intentionally skip RDS Proxy to avoid stacking two poolers.
10. **Cluster endpoint baked into IaC outputs.** Terraform modules commonly output `cluster_endpoint` / `writer_endpoint`. Downstream services consume that output. Unless the module was updated to expose the proxy endpoint (and downstreams re-run to pick it up), new services keep landing direct.

---

## 5. How to prove which bypass reasons apply — troubleshooting playbook

Do these in order. #1 and #2 alone will identify most of the offenders.

### 5.1. Snapshot `pg_stat_activity` and classify by `client_addr`

Run on the current writer (`ims-account-aurora-us-west-2-cluster-2`):

```sql
SELECT
    client_addr,
    usename,
    application_name,
    datname,
    state,
    count(*)                                   AS sessions,
    max(now() - backend_start)                 AS oldest_session_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND client_addr IS NOT NULL
GROUP BY 1, 2, 3, 4, 5
ORDER BY sessions DESC;
```

Cross-reference `client_addr` against the proxy's ENI private IPs:

```bash
aws --region us-west-2 ec2 describe-network-interfaces \
    --filters Name=description,Values="RDSProxy*" \
    --query 'NetworkInterfaces[].{IP:PrivateIpAddress,Desc:Description,SG:Groups[].GroupId}' \
    --output table
```

Any `client_addr` that is **not** a proxy ENI IP is a bypass. `application_name` + `usename` will usually name the offender directly.

### 5.2. Identify the owning service for each bypass IP

For each bypass `client_addr`:

```bash
aws --region us-west-2 ec2 describe-network-interfaces \
    --filters Name=addresses.private-ip-address,Values=<ip> \
    --query 'NetworkInterfaces[].{ENI:NetworkInterfaceId,Instance:Attachment.InstanceId,Desc:Description,SG:Groups[].GroupId}' \
    --output table

aws --region us-west-2 ec2 describe-instances \
    --instance-ids <instance-id> \
    --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Service:Tags[?Key==`service`]|[0].Value,Repo:Tags[?Key==`repo`]|[0].Value,Env:Tags[?Key==`environment`]|[0].Value,ASG:Tags[?Key==`aws:autoscaling:groupName`]|[0].Value}' \
    --output table
```

If the ENI belongs to EKS pods (description `aws-K8S-i-...`), pull the pod owning the IP:

```bash
kubectl get pods -A -o wide | awk '$7=="<ip>"'
```

If the ENI is a NAT gateway or VPC endpoint, the traffic is cross-account/cross-VPC — trace via VPC Flow Logs (§5.6).

### 5.3. grep every repo for the direct endpoints

```bash
DIRECT_HOSTS=(
    "ims-account-aurora-us-west-2-cluster.cluster-c38c4oymc9wd.us-west-2.rds.amazonaws.com"
    "ims-account-aurora-us-west-2-cluster.cluster-ro-c38c4oymc9wd.us-west-2.rds.amazonaws.com"
    "ims-account-aurora-us-west-2-cluster-0.c38c4oymc9wd.us-west-2.rds.amazonaws.com"
    "ims-account-aurora-us-west-2-cluster-1.c38c4oymc9wd.us-west-2.rds.amazonaws.com"
    "ims-account-aurora-us-west-2-cluster-2.c38c4oymc9wd.us-west-2.rds.amazonaws.com"
)
for h in "${DIRECT_HOSTS[@]}"; do
    gh search code --owner <your-github-org> "$h" --limit 100
done
```

Also scan Terraform state / Terragrunt outputs for `cluster_endpoint` / `writer_endpoint` / `reader_endpoint` consumers.

### 5.4. Verify each candidate app can even use the proxy

For a shortlisted service, check three things in order:

1. **Does its DB secret match the proxy secret?**
   ```bash
   aws --region us-west-2 secretsmanager list-secrets \
       --filters Key=name,Values=account-db-prod \
       --query 'SecretList[].{Name:Name,ARN:ARN,LastAccessed:LastAccessedDate}' \
       --output table
   ```
   Compare each to `Auth[0].SecretArn` on the proxy. If different, this service literally cannot use the proxy without a secret change on the proxy or the app.
2. **Does its SG have ingress to `sg-0c01aa6afc4213e65:5432`?**
   ```bash
   aws --region us-west-2 ec2 describe-security-groups \
       --group-ids sg-0c01aa6afc4213e65 \
       --query 'SecurityGroups[].IpPermissions[?FromPort==`5432`]' \
       --output json
   ```
3. **Does its driver support SCRAM-SHA-256 + mandatory TLS?**
   - Postgres client library ≥ libpq 10, node-postgres ≥ 8, JDBC ≥ 42.2.6, `psycopg2` ≥ 2.8, Go `pgx` ≥ 4, Go `pq` ≥ current, .NET `Npgsql` ≥ 4.
   - DSN must include `sslmode=require` (or stricter) and no `password_encryption=md5` clamp.

If any of the three fails, that service will not talk to the proxy until it's fixed. Fix at the app layer, then repoint.

### 5.5. Enable proxy audit logging temporarily

If you need to see which apps *tried* the proxy and failed vs never tried at all, enable enhanced logging on the proxy:

```bash
aws --region us-west-2 rds modify-db-proxy \
    --db-proxy-name account-db-prod-proxy-us-west-2 \
    --debug-logging
```

Logs go to CloudWatch Logs under `/aws/rds/proxy/account-db-prod-proxy-us-west-2`. Turn it off after a business-day window — `--debug-logging` is verbose and increases cost. Do not leave on permanently.

### 5.6. VPC Flow Logs on the cluster ENIs

Get the cluster's ENIs and check flow logs for the incident window:

```bash
aws --region us-west-2 rds describe-db-instances \
    --db-instance-identifier ims-account-aurora-us-west-2-cluster-0 \
    --query 'DBInstances[].Endpoint.Address' --output text

# Resolve to ENI:
aws --region us-west-2 ec2 describe-network-interfaces \
    --filters Name=description,Values="*ims-account-aurora*" \
    --query 'NetworkInterfaces[].{ENI:NetworkInterfaceId,IP:PrivateIpAddress,Desc:Description}' \
    --output table
```

Then query CloudWatch Logs Insights against the flow-log group filtering on `dstPort = 5432` and `dstAddr = <ENI IP>` for the 22:00–01:00 UTC window. Top `srcAddr` list = bypassers ordered by connection count.

### 5.7. Sanity-check for `LISTEN/NOTIFY` and other pin-triggers

Some apps intentionally use `LISTEN/NOTIFY` for pub-sub (Postgres-backed job queues like `pg_notify`-based systems). Those genuinely cannot use RDS Proxy for Postgres today — it does not proxy async notifications. Grep for:

```bash
grep -rE "\bLISTEN\b|pg_notify|NOTIFY " <repos>/
```

For each hit, decide: run those clients direct (documented exception) or migrate off `LISTEN/NOTIFY` (SNS/SQS, Redis pub/sub, etc.). Do the same audit for `WITH HOLD`, session-level `SET`, temp-table lifespans, and advisory locks — all common pin causes.

---

## 6. Prioritized fixes

Priorities 1–5 restate/extend the existing [`report.md`](./report.md) recommendations. Anything with a `1x` label is the RDS Proxy addendum.

### Priority 1a — Force applications through the proxy at the network layer (highest impact)

Code-level "please use the proxy endpoint" conventions drift. Enforce with SGs:

- **Only `sg-0c01aa6afc4213e65` (the proxy SG) is allowed onto the Aurora cluster SG on 5432.**
- Strip every application SG from the Aurora SG's port 5432 ingress.
- Add exceptions ONLY for the documented bypass list (BI, migrations, DMS, DR paths — see §5.7).
- Do this in Terraform on the module that owns the Aurora SG. Roll out per app team so on-call knows what to expect.

This is the single change that would have prevented the incident.

### Priority 1b — Raise DB `max_connections`

- Current ~290 (Aurora default for the instance class) → proxy ceiling 261.
- On a **custom cluster parameter group**, set `max_connections = 2000` (or higher after instance-size review). With `MaxConnectionsPercent = 90 %` this gives a 1,800-connection proxy pool.
- Verify the writer instance class can support it: `LEAST({DBInstanceClassMemory/9531392}, 5000)` — likely wants `db.r6g.2xlarge` or larger. Size-up first if needed; a big `max_connections` on a small instance just moves the failure to `work_mem` × sessions memory exhaustion.
- Requires a restart of each instance to apply. Sequence: reader-1 → reader-2 → failover → old-writer.

### Priority 1c — Tune `ConnectionBorrowTimeout` deliberately

- Current 5 s = fail fast. Correct choice IF Priority 1a and 1b are done.
- If you want to absorb short DB blips instead, raise to 15–30 s. Trade-off: slow queries pile up on the client side and app pools starve.
- Do not raise it without also fixing `max_connections`, or you'll just hide the exhaustion for longer.

### Priority 1d — Add proxy-level CloudWatch alarms

| Metric                                                          | Threshold                 | Comparison           | Period | Consecutive |
|-----------------------------------------------------------------|---------------------------|----------------------|--------|-------------|
| `DatabaseConnectionsBorrowLatency`                              | 100,000 (100 ms)          | GreaterThanThreshold | 60 s   | 3           |
| `DatabaseConnections` / `MaxDatabaseConnectionsAllowed` (math)  | 80 %                      | GreaterThanThreshold | 60 s   | 3           |
| `ClientConnectionsSetupFailedAuth`                              | 0                         | GreaterThanThreshold | 60 s   | 1           |
| `DatabaseConnectionsCurrentlySessionPinned`                     | 0                         | GreaterThanThreshold | 60 s   | 5           |
| `ClientConnectionsReceived` (rate)                              | 500 /min                  | GreaterThanThreshold | 60 s   | 3           |

The `DatabaseConnectionsBorrowLatency` alarm would have fired at ~22:55 UTC — **5 minutes ahead of the first human page** and 1 h 20 m ahead of the failover.

### Priority 1e — Onboard bypassers systematically

Use §5 to build a spreadsheet of every service currently connecting to the cluster endpoints. For each, one of three dispositions:

| Disposition            | Meaning                                                                                          | Actions                                                                              |
|------------------------|--------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| **Migrate to proxy**   | App CAN use proxy (secret, SG, driver, features all compatible)                                  | Change DSN → proxy endpoint. Update Terraform / Helm / Secrets Manager. Redeploy.    |
| **Fix then migrate**   | App has a fixable blocker (old driver, wrong SG, wrong secret, TLS disabled)                     | Track the fix as a ticket per app. Migrate after fix ships.                          |
| **Permanent exception**| App genuinely can't use proxy (`LISTEN/NOTIFY`, cross-region write, DMS/Glue/migrations, BI)     | Document. Grant explicit SG ingress. Cap those apps at a known session budget.        |

### Priority 1f — Second proxy for us-east-1 (optional, DR-driven)

If workloads in us-east-1 write to the writer cross-region OR you want DR-ready failover routing, provision a second RDS Proxy in us-east-1 pointing at the global cluster's local secondary. Application config then uses a region-aware endpoint. Skip if all writes originate in us-west-2 and you accept direct-to-writer during DR failback.

---

## 7. What was NOT investigated / open questions

- **Per-target proxy metrics.** RDS Proxy also emits metrics with `Target` dimension (per-instance / per-tracked-cluster). Not pulled here — the aggregate ProxyName view was sufficient to prove pool exhaustion. Pull if you need to attribute borrow latency to a specific reader vs writer.
- **`ClientConnectionsSetupFailedAuth` = zero over the whole window.** Confirms no auth-failure storm during the incident; does NOT tell us if apps that never went through the proxy would have failed auth if they'd tried. §5.4 covers that.
- **Proxy CPU / memory / pinning root causes.** RDS Proxy is managed — no CPU/memory metric is exposed to customers. If AWS Support believes the proxy itself was under-provisioned, that would need a support case.
- **Cross-region connections in us-east-1.** No proxy exists there, so bypass in that region is 100 % by design. Not counted in the 94 % bypass figure.
- **Content Services connection pattern specifically.** Report notes CS severed connections at 00:10 UTC and it helped. Whether CS was going through the proxy or direct is not confirmed — use §5.1 during business hours to tag it.

---

## 8. File inventory (this addendum)

| File                                                                 | Purpose                                            |
|----------------------------------------------------------------------|----------------------------------------------------|
| [`rds-proxy-findings.md`](./rds-proxy-findings.md)                   | This document                                      |
| [`rds-proxy/proxy-describe.json`](./rds-proxy/proxy-describe.json)   | Full `describe-db-proxies` output                  |
| [`rds-proxy/proxy-target-groups.json`](./rds-proxy/proxy-target-groups.json) | Target group config (pool sizing, borrow timeout) |
| [`rds-proxy/proxy-targets.json`](./rds-proxy/proxy-targets.json)     | Registered targets (all 3 us-west-2 instances)     |
| [`rds-proxy/proxy-endpoints.json`](./rds-proxy/proxy-endpoints.json) | Additional proxy endpoints (none custom)           |
| [`rds-proxy/pull-proxy-metrics.sh`](./rds-proxy/pull-proxy-metrics.sh) | CloudWatch pull script (reproducible)            |
| [`rds-proxy/metrics/`](./rds-proxy/metrics/)                         | Raw per-metric CloudWatch responses                |
| [`rds-proxy/proxy-metrics-1min.csv`](./rds-proxy/proxy-metrics-1min.csv) | Aggregated 1-min proxy metrics as CSV          |
| [`rds-proxy/proxy-metrics-summary.md`](./rds-proxy/proxy-metrics-summary.md) | Peak/avg + per-anchor snapshot summary      |
| [`rds-proxy/summarize.py`](./rds-proxy/summarize.py)                 | Summary builder                                    |
