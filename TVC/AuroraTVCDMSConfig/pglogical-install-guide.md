# Installing PostgreSQL Extensions for GCP DMS (Aurora → CloudSQL)

Reference guide derived from the `aurora-tvc-qa-dms-*` scripts in this
directory. Applies to a **continuous (CDC)** GCP Database Migration Service job
from **Aurora PostgreSQL (source)** to **CloudSQL PostgreSQL (destination)**.

- Source: `tvc-qa` Aurora cluster, `us-east-1`
- Destination: CloudSQL Postgres `tvc-qa`, `us-east4`, project
  `vz-inscape-portfolio-qa`
- DMS user: `root` (Aurora master user)
- DMS job: `tvc-qa-aurora`

---

## TL;DR

GCP DMS for Postgres uses **pglogical** for logical decoding on the source.
You install it in three layers:

| Layer             | Where             | What you do                                                                                     |
|-------------------|-------------------|-------------------------------------------------------------------------------------------------|
| 1. Cluster params | AWS control plane | Turn on `rds.logical_replication`, add `pglogical` to `shared_preload_libraries`, reboot writer |
| 2. Roles          | Any DB, once      | `GRANT rds_replication, rds_superuser TO root;`                                                 |
| 3. Extension      | **Every user DB** | `CREATE EXTENSION pglogical;` + schema/table grants for `root`                                  |

Only the extension itself (`pglogical`) is required. No `pgcrypto`,
`postgres_fdw`, etc. are needed for DMS.

---

## The one extension DMS needs

**`pglogical`** — logical replication provider used by GCP DMS to decode WAL
on the source and stream row-level changes.

- Ships with Aurora PostgreSQL; no external install needed.
- Must be preloaded via `shared_preload_libraries` (static parameter,
  requires reboot).
- Must be installed **in every database** the DMS job replicates.
- Do **not** manually create pglogical nodes or subscriptions — DMS creates
  its own when the job starts and will collide with any pre-existing ones.

---

## Layer 1 — Cluster parameter group patch

Automated by [`aurora-tvc-qa-dms-prep.sh`](aurora-tvc-qa-dms-prep.sh).

Two parameters, both **static** (pending-reboot) on Aurora:

| Parameter                  | Required value           | Why                                                                                                                |
|----------------------------|--------------------------|--------------------------------------------------------------------------------------------------------------------|
| `rds.logical_replication`  | `1`                      | Aurora meta-parameter that flips `wal_level=logical`. Without this, no logical decoding, no CDC.                   |
| `shared_preload_libraries` | must include `pglogical` | Preloads the pglogical shared library at postmaster start so `CREATE EXTENSION pglogical` can succeed inside a DB. |

### Prereqs
- Cluster is on a **custom** cluster parameter group (defaults are immutable
  — the script refuses to run against `default.*`).
- AWS CLI v2 authenticated with:
  `rds:DescribeDBClusters`,
  `rds:DescribeDBClusterParameters`,
  `rds:ModifyDBClusterParameterGroup`,
  `rds:RebootDBInstance`.
- Short maintenance window for a writer reboot (~10–60s).

### Run it
```bash
./aurora-tvc-qa-dms-prep.sh
```
The script:
1. Auto-discovers the attached cluster parameter group.
2. Merges `pglogical` into `shared_preload_libraries` (preserves existing
   entries; idempotent).
3. Sets `rds.logical_replication=1`.
4. Reboots the writer and waits for `available`.

### Verify after reboot
Connect and eyeball:
```sql
SHOW wal_level;                 -- logical
SHOW rds.logical_replication;   -- on
SHOW shared_preload_libraries;  -- contains "pglogical"
```
Any mismatch → the parameter-group patch didn't land; re-run the script.

### What was intentionally NOT changed
- `max_replication_slots`, `max_wal_senders`, `max_worker_processes` —
  Aurora defaults cover a single DMS job (1 slot + 1 sender + ~4 workers).
- `wal_sender_timeout` — leave at 60s. Setting `0` disables dead-connection
  detection and risks a stuck slot + unbounded WAL retention if DMS drops
  its TCP session silently.
- `rds.force_ssl` — leave `1`. DMS source profile uses the RDS CA bundle.

---

## Layer 2 — Grant DMS the RDS-managed roles (once)

Run once, in any database, as the Aurora master user:

```sql
GRANT rds_replication TO root;
GRANT rds_superuser   TO root;
```

| Role              | Why                                                                                                                                                                               |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `rds_replication` | RDS-managed equivalent of the `REPLICATION` attribute AWS otherwise blocks. Required to open a logical replication connection.                                                    |
| `rds_superuser`   | Aurora's proxy for `SUPERUSER` (real `SUPERUSER` is not exposed). pglogical needs it to create replication slots, register nodes, and read all schemas without per-object grants. |

Connect over TLS with the RDS CA bundle:
```bash
psql "host=tvc-qa.cujpo2r0mujo.us-east-1.rds.amazonaws.com \
      port=5432 dbname=postgres user=root \
      sslmode=verify-full \
      sslrootcert=/Users/michael.dspain/Documents/rds-us-east-1-bundle.pem"
```

---

## Layer 3 — Install pglogical in every user database

pglogical is **per-database**. You must run the install block in every DB the
DMS job will migrate (skip `rdsadmin` and, if unused, `postgres`).

### Option A — Automated loop (recommended)

[`aurora-tvc-qa-dms-install-perdb.sh`](aurora-tvc-qa-dms-install-perdb.sh)
enumerates every user DB (`datistemplate=false`, excluding `rdsadmin` and
`postgres`) and executes
[`aurora-tvc-qa-dms-perdb.pgsql`](aurora-tvc-qa-dms-perdb.pgsql) against
each. Idempotent — safe to re-run.

```bash
PGPASSWORD='<root pw>' ./aurora-tvc-qa-dms-install-perdb.sh
```

The wrapper reports pass/fail per DB and exits non-zero if any DB failed.

### Option B — Manual, per DB

Connect to each target DB (`\c <dbname>`) and run:

```sql
-- Install the extension (requires shared_preload_libraries preload).
CREATE EXTENSION IF NOT EXISTS pglogical;

-- Give the DMS user the pglogical schema.
ALTER SCHEMA pglogical OWNER TO root;
GRANT USAGE ON SCHEMA pglogical TO root;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO root;

-- Grant DMS read on every user schema + future objects.
DO $$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog','information_schema','pglogical')
      AND nspname NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO root', s);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO root', s);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO root', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO root', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO root', s);
  END LOOP;
END$$;
```

Why the grants:
- `USAGE` — name-resolution inside each schema.
- `SELECT` on tables — initial snapshot copy.
- `SELECT` on sequences — capture sequence values.
- `ALTER DEFAULT PRIVILEGES` — future tables/sequences remain readable so
  post-prep DDL doesn't silently break the migration.

### Verify per DB
```sql
-- Extension present
SELECT extname, extversion FROM pg_extension WHERE extname = 'pglogical';

-- No leftover pglogical nodes (expect 0 rows on a fresh source)
SELECT node_id, node_name FROM pglogical.node;

-- No leftover subscriptions (expect 0 rows on a fresh source)
SELECT sub_id, sub_name, sub_enabled FROM pglogical.subscription;
```

> **Do not** call `pglogical.show_subscription_status()` on a fresh source.
> It raises `current database is not configured as pglogical node` when no
> pglogical node exists — which is the correct state. DMS creates the node
> itself when the job starts.

---

## CDC readiness audit — required before starting the job

pglogical needs a way to uniquely identify every replicated row:

- **PRIMARY KEY** — best; nothing to do.
- **REPLICA IDENTITY FULL** — works but heavy (every UPDATE ships the whole
  old row).
- **REPLICA IDENTITY USING INDEX** — works only if the index is `UNIQUE` and
  all columns are `NOT NULL`.

Tables with none of the above **cannot** be CDC-replicated; DMS will fail
during apply. Find them per DB:

```sql
SELECT n.nspname AS schema,
       c.relname AS table,
       c.relreplident AS replica_identity  -- d=default(PK), n=nothing, f=full, i=index
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pglogical')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  )
ORDER BY 1,2;
```

Remediate each row (in preference order):
1. `ALTER TABLE <schema>.<table> ADD PRIMARY KEY (<cols>);`
2. `ALTER TABLE <schema>.<table> REPLICA IDENTITY USING INDEX <unique_not_null_idx>;`
3. `ALTER TABLE <schema>.<table> REPLICA IDENTITY FULL;`  *(last resort)*

The per-DB script emits this audit automatically; review before starting the
DMS job.

---

## Rollback

Only do this **when the DMS job is stopped**. Dropping `pglogical` destroys
any active logical replication slots inside that DB.

Per DB:
```sql
DROP EXTENSION IF EXISTS pglogical;
```

Cluster:
```sql
REVOKE rds_replication, rds_superuser FROM root;
```
```bash
aws rds modify-db-cluster-parameter-group \
  --region us-east-1 \
  --db-cluster-parameter-group-name <CLUSTER_PG> \
  --parameters \
    ParameterName=rds.logical_replication,ParameterValue=0,ApplyMethod=pending-reboot \
    ParameterName=shared_preload_libraries,ParameterValue=<original>,ApplyMethod=pending-reboot
# then reboot the writer.
```

---

## Runbook order

1. `./aurora-tvc-qa-dms-prep.sh` — cluster params + writer reboot.
2. Connect as `root` and run
   [`aurora-tvc-qa-dms-cluster-grants.pgsql`](aurora-tvc-qa-dms-cluster-grants.pgsql)
   once against any DB on the cluster (grants `rds_replication` +
   `rds_superuser`, prints the three `SHOW` sanity checks).
3. `PGPASSWORD=... ./aurora-tvc-qa-dms-install-perdb.sh` — installs
   pglogical + grants in every user DB, prints CDC-blocking tables per DB.
4. Fix any tables reported by the audit (add PK / replica identity).
5. Start the GCP DMS job `tvc-qa-aurora`.

---

## Script index

| File                                                                                     | Purpose                                                                            |
|------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------|
| [`aurora-tvc-qa-dms-prep.sh`](aurora-tvc-qa-dms-prep.sh)                                 | AWS-side cluster parameter patch + writer reboot                                   |
| [`aurora-tvc-qa-dms-cluster-grants.pgsql`](aurora-tvc-qa-dms-cluster-grants.pgsql)       | One-shot cluster grants (`rds_replication`, `rds_superuser`) + `SHOW` sanity checks |
| [`aurora-tvc-qa-dms-install-perdb.sh`](aurora-tvc-qa-dms-install-perdb.sh)               | Loops over every user DB and applies the per-DB SQL                                |
| [`aurora-tvc-qa-dms-perdb.pgsql`](aurora-tvc-qa-dms-perdb.pgsql)                         | Idempotent per-DB payload: `CREATE EXTENSION pglogical` + grants + audit           |
