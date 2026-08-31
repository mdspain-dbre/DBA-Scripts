# Aurora Health Check Prompt

You are a Aurora Postgres Database Expert **

**Investigate database health and if there is performance degradation on the following two instances

ARN of RDS instance: arn:aws:rds:us-east-1:788724168120:cluster:tvc-development-cluster

arn:aws:rds:us-east-1:788724168120:cluster:tvc-qa-cluster

Database Endpoint: **tvc-development-cluster.cluster-cujpo2r0mujo.us-east-1.rds.amazonaws.com**

**tvc-qa-cluster.cluster-cujpo2r0mujo.us-east-1.rds.amazonaws.com**

Type of issue and error::performance degradation or connection issues 

**AWS Acount | Inscape Production US 1.**

**Account ID | 788724168120******

Dates to investigate for **  the last 5 hours ******

Using this directory to put all files /Users/michael.dspain/Documents/DBA-Scripts/PromptScriptsOutput

Pull CloudWatch metrics at 1-minute granularity: CPUUtilization, DatabaseConnections, ReadIOPS/ReadLatency, WriteIOPS, FreeableMemory,  SwapUsage, NetworkReceiveThroughput, DiskQueueDepth, RDS Events and other SQL Server metrics that will help  with the analysis  for that window.

Also pull Aurora-specific CloudWatch metrics: AuroraReplicaLag (if a reader exists), BufferCacheHitRatio, VolumeReadIOPs / VolumeWriteIOPs, VolumeBytesUsed, CommitLatency, DDLLatency, LoginFailures, and (if Aurora Serverless v2) ServerlessDatabaseCapacity.

Compare Memory consumption for the same time window on the two prior same-weekdays to determine if this is a recurring pattern or one-time anomaly.

Also determine if temp tables are being written to disk

Determine queries that are consuming large amounts of memory and causing IO contention  

## Postgres-specific checks (via read-only SQL, when DB credentials are available)

Run the read-only sections of `Postgres/pg_healthcheck.sql` against each instance (connect to the `postgres` database) and interpret:

- **Connections vs `max_connections`** — flag if `pct_used` > 80%; note any `idle in transaction` sessions (they hold locks/XIDs).
- **Long-running active queries (> 5s)** — candidates for the "consuming large memory / causing IO contention" question above.
- **Cache hit ratio, deadlocks, conflicts, temp files (per database)** — cache hit ratio target ≥ 99%; growing temp-file counts indicate `work_mem` pressure (the Postgres equivalent of "temp tables written to disk").
- **Database sizes** — track growth that could explain storage/IO pressure.
- **Replication** — on the writer, check downstream standby/reader lag; on a reader, check its own replay lag (`pg_last_wal_receive_lsn` vs `pg_last_wal_replay_lsn` / `AuroraReplicaLag`).
- **Transaction ID (XID) wraparound risk** — flag if `age(datfrozenxid)` is > 50% of `autovacuum_freeze_max_age`.
- **Blocked sessions / lock waits** — pair blockers with waiters (`pg_locks` / `pg_stat_activity`).
- **Dead tuples & autovacuum activity** — tables with high dead-tuple ratio or autovacuum falling behind.
- **Unused/rarely-used indexes** — candidates for cleanup, but only note them, don't drop anything.
- **Checkpoints & bgwriter I/O health** — frequent forced checkpoints or high `buffers_backend` vs `buffers_clean` indicates I/O contention.
- **Top time-consuming statements** — via `pg_stat_statements` if the extension is installed; this is the primary way to identify which queries are consuming memory/IO.
- **`pglogical` replication status** — if the `pglogical` extension is installed, check whether it's actually replicating:
  - `SELECT * FROM pglogical.node;` and `SELECT * FROM pglogical.node_interface;` to confirm the node(s) are configured.
  - `SELECT * FROM pglogical.subscription;` plus `SELECT subscription_name, status FROM pglogical.show_subscription_status();` on the subscriber — flag any subscription with `status <> 'replicating'` (e.g., `down`, `disconnected`, `initializing` stuck).
  - On the provider, check for orphaned/inactive replication slots (`SELECT slot_name, active, restart_lsn, wal_status FROM pg_replication_slots WHERE slot_type = 'logical';`) — an inactive logical slot retains WAL indefinitely and can drive storage growth / IO pressure even though `pglogical` itself looks "off".
  - Confirm whether pglogical being off is **expected** (e.g., decommissioned integration) vs. an unexpected outage; if a slot is inactive and retaining WAL, that is itself a finding to call out, since it can be a root cause of the reported degradation.

If DB credentials aren't available for direct SQL, note each of the above as a **skipped check** rather than omitting it, and rely on the CloudWatch/Performance Insights equivalents instead (e.g., `BufferCacheHitRatio` for cache hit ratio, Performance Insights top-SQL for top statements).

Extract unique source IPs from the slow query logs and trace them back to their EC2 instances using aws ec2 describe-network-interfaces and describe-instances. Identify the service name, instance type, function, and any repo tags.

Check EventBridge rules for any scheduled jobs that could have triggered the activity.

Check the Auto-Scaling Group configuration for any identified services.

Generate a markdown document with all findings including: metric summary tables, slow query analysis, source service identification table with IPs mapped to services, the methodology used (how repos/services were identified), a timeline of what happened, and actionable next steps.  Be sure all column padding aligns.
