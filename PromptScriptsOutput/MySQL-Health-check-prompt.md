# MySQL Health Check Prompt (template)

You are a MySQL Database Expert.

**Investigate database health and whether there is performance degradation on the following instance(s):**

ARN of RDS instance: `<arn:aws:rds:<region>:<account-id>:db:<db-instance-identifier>>`

Database Endpoint: `<db-instance-identifier>.<random-suffix>.<region>.rds.amazonaws.com`

Type of issue and error: `<performance degradation | connection issues | replication lag | high CPU | disk space | other>`

**AWS Account:** `<account-name, e.g. Inscape Production US 1>`

**Account ID:** `<account-id>`

**Dates to investigate for:** `<e.g. the last 5 hours | 2026-08-27 09:00-14:00 UTC>`

Using this directory to put all files: `/Users/michael.dspain/Documents/DBA-Scripts/PromptScriptsOutput`

## What to pull

- Pull CloudWatch metrics at 1-minute granularity: `CPUUtilization`, `DatabaseConnections`, `ReadIOPS`/`ReadLatency`, `WriteIOPS`/`WriteLatency`, `FreeableMemory`, `SwapUsage`, `NetworkReceiveThroughput`/`NetworkTransmitThroughput`, `DiskQueueDepth`, and any other MySQL-relevant RDS metrics for that window.
- Pull RDS Events (`aws rds describe-events`) for the instance (and any read replicas) over the same window.
- Compare memory (`FreeableMemory`) and connection count for the same time window on the two prior same-weekdays to determine if this is a recurring pattern or a one-time anomaly.
- Check replication status/lag if this instance has read replicas (`ReplicaLag` CloudWatch metric, plus `SHOW REPLICA STATUS` if DB credentials are available).
- Determine whether temp tables are being written to disk (`Created_tmp_disk_tables` vs `Created_tmp_tables`, via Performance Insights counters or a read-only `SHOW GLOBAL STATUS` query if credentials are available).
- Determine InnoDB buffer pool hit ratio and any memory pressure signals (`Innodb_buffer_pool_read_requests` vs `Innodb_buffer_pool_reads`).
- Determine queries consuming large amounts of memory/CPU and causing IO contention — use Performance Insights top-SQL by DB load, or the slow query log if available.
- Check for lock contention / deadlocks (`SHOW ENGINE INNODB STATUS`, `information_schema.innodb_trx`, `performance_schema.data_lock_waits`) if DB credentials are available.
- Confirm whether the slow query log is enabled (`slow_query_log`, `long_query_time` parameter group values) and whether it's exported to CloudWatch Logs (`EnabledCloudwatchLogsExports`) before assuming log data is available.

## Slow query / source tracing (only if slow query log data is available)

- Extract unique source IPs from the slow query logs and trace them back to their EC2 instances using `aws ec2 describe-network-interfaces` and `aws ec2 describe-instances`. Identify the service name, instance type, function, and any repo tags.
- Check EventBridge rules for any scheduled jobs that could have triggered the activity.
- Check the Auto Scaling Group configuration for any identified services.

## Output

Generate a markdown document with all findings including: metric summary tables (padded/aligned columns), replication status, slow query analysis, source service identification table (IPs mapped to services), the methodology used (how repos/services were identified), a timeline of what happened, and actionable next steps. If a section couldn't be completed (e.g., no DB credentials, logs not exported, IAM permission gap), say so explicitly rather than omitting it — note it as a gap.

## Constraints

- Strictly read-only: only `list`/`describe`/`get`-style AWS CLI calls and `SELECT`/`SHOW`/`EXPLAIN` SQL. Never run mutating AWS or SQL commands.
- Always pass the explicit account/region/instance identifier on every call to avoid cross-environment contamination.
- If AWS auth is missing or expired, stop and say so rather than guessing at results.
