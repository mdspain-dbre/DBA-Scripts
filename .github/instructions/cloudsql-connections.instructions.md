---
description: "Database connection reference for the Inscape portfolio projects (vz-inscape-portfolio-dev / -qa / -stage): CloudSQL MySQL/Postgres and AlloyDB instance names, regions, connection names, and Auth Proxy ports. Consult before connecting to any instance or running a health check / backup audit."
applyTo: "GCP/**,**/*cloudsql*,**/*CloudSQL*,**/*alloydb*,**/*AlloyDB*"
---
# Database Connection Reference — Inscape portfolio (`dev` / `qa` / `stage`)

Standard facts for connecting to CloudSQL and AlloyDB instances across `vz-inscape-portfolio-dev`, `vz-inscape-portfolio-qa`, and `vz-inscape-portfolio-stage`. Keep these tables up to date; agents and prompts rely on them so they don't have to rediscover connection details every run.

> Inventory last verified: 2026-07-27. Re-run the discovery commands under each section if instances have changed.

## Connection conventions
- **Always connect via a proxy** — never expose public IP or embed passwords. CloudSQL uses the **Cloud SQL Auth Proxy**; AlloyDB uses the **AlloyDB Auth Proxy** (`alloydb-auth-proxy`) against the instance URI, or an existing PSC/private-IP path.
- CloudSQL connection name format: `<project>:<region>:<instance>`.
- Start the proxy, then connect over `127.0.0.1:<local-port>`; tear the proxy down when finished.
  - IAM auth: `cloud-sql-proxy --auto-iam-authn --port <local-port> <project>:<region>:<instance>`
  - Built-in auth: `cloud-sql-proxy --port <local-port> <project>:<region>:<instance>` then `psql`/`mysql` with the DB user.
- Default local ports: **Postgres 5432**, **MySQL 3306**. When sweeping multiple projects/instances at once, increment ports (5433, 5434, … / 3307, 3308, …) to avoid collisions — the suggested per-project ports in the tables below keep dev/qa/stage from clashing.

## CloudSQL instances
> Discover live values with:
> `gcloud sql instances list --project=<project> --format="table(name,databaseVersion,region,settings.availabilityType,settings.tier,connectionName)"`

### `vz-inscape-portfolio-dev` (suggested Postgres port 5432, MySQL 3306)

| Instance | Engine / Version | Region | Connection name | Local port | Notes |
|----------|------------------|--------|-----------------|------------|-------|
| `admin-portal-db` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-dev:us-east4:admin-portal-db` | 5432 | ZONAL, db-custom-2-8192 |
| `tvc-development` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-dev:us-east4:tvc-development` | 5432 | ZONAL, db-custom-2-8192 |
| `client-cert-auxdb` | MYSQL_8_4 | us-west1 | `vz-inscape-portfolio-dev:us-west1:client-cert-auxdb` | 3306 | ZONAL, db-custom-4-26624 |
| `prod-gcp-auxdb-qa-84-20260226` | MYSQL_8_4 | us-west1 | `vz-inscape-portfolio-dev:us-west1:prod-gcp-auxdb-qa-84-20260226` | 3306 | ZONAL, db-custom-4-26624; replica of `…-master` |
| `auxdb-qa-dre-test` | MYSQL_8_0 | us-west1 | `vz-inscape-portfolio-dev:us-west1:auxdb-qa-dre-test` | 3306 | ZONAL, db-custom-2-7680 (DRE test) |
| `auxdb-qa-dre-test2` | MYSQL_8_0 | us-west1 | `vz-inscape-portfolio-dev:us-west1:auxdb-qa-dre-test2` | 3306 | ZONAL, db-custom-2-7680; replica of `…-master` (DRE test) |
| `auxdb-dre-test3` | MYSQL_8_0 | us-west1 | `vz-inscape-portfolio-dev:us-west1:auxdb-dre-test3` | 3306 | ZONAL, db-custom-2-7680 (DRE test) |
| `prod-gcp-auxdb-qa-84-20260226-master` | MYSQL_8_0 | us-west1 | — | — | External-primary source row (no proxy target) for the replica above |
| `auxdb-qa-dre-test2-master` | MYSQL_8_0 | us-west1 | — | — | External-primary source row (no proxy target) for the replica above |

### `vz-inscape-portfolio-qa` (suggested Postgres port 5433)

| Instance | Engine / Version | Region | Connection name | Local port | Notes |
|----------|------------------|--------|-----------------|------------|-------|
| `admin-portal-db` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-qa:us-east4:admin-portal-db` | 5433 | ZONAL, db-custom-2-8192 |
| `tvc-qa` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-qa:us-east4:tvc-qa` | 5433 | ZONAL, db-custom-2-8192 |

### `vz-inscape-portfolio-stage` (suggested Postgres port 5434)

| Instance | Engine / Version | Region | Connection name | Local port | Notes |
|----------|------------------|--------|-----------------|------------|-------|
| `admin-portal-db` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-stage:us-east4:admin-portal-db` | 5434 | **REGIONAL (HA)**, db-custom-2-8192 |
| `tvcdb-stage` | POSTGRES_18 | us-east4 | `vz-inscape-portfolio-stage:us-east4:tvcdb-stage` | 5434 | **REGIONAL (HA)**, db-custom-2-8192; replica of `…-master` |
| `tvcdb-stage-master` | POSTGRES_17 | us-east4 | — | — | External-primary source row (no proxy target) for the replica above |

## AlloyDB clusters / instances
> Discover live values with:
> `gcloud alloydb clusters list --project=<project> --region=- --format="table(name,databaseVersion,state)"` then
> `gcloud alloydb instances list --project=<project> --region=<region> --cluster=<cluster> --format="table(name.basename(),instanceType,state,machineConfig.cpuCount,availabilityType)"`
>
> AlloyDB has no public IP — connect via `alloydb-auth-proxy <instance-uri> --port <local-port>` (or an existing PSC/private-IP path). Instance URI: `projects/<project>/locations/<region>/clusters/<cluster>/instances/<instance>`. The `pg_healthcheck.sql` script applies (AlloyDB is Postgres-compatible).

### `vz-inscape-portfolio-dev` — region `us-east4` (suggested port 5442)

| Cluster | Instance | Type | CPUs | Notes |
|---------|----------|------|------|-------|
| `pointsdb-video-clu` | `pointsdb-video-inst` | PRIMARY | 16 | POSTGRES_18, ZONAL, READY |
| `pointsdb-video-clu` | `pointsdb-video-read-pool` | READ_POOL | 16 | READY |
| `pointsdb-audio-clu` | `pointsdb-audio-inst` | PRIMARY | 8 | POSTGRES_18, ZONAL, READY |
| `pointsdb-audio-clu` | `pointsdb-audio-read-pool` | READ_POOL | 8 | READY |
| `tvc-development-cluster` | `tvc-development` | PRIMARY | 2 | POSTGRES_17, ZONAL, READY |

### `vz-inscape-portfolio-qa` — region `us-east4` (suggested port 5443)

| Cluster | Instance | Type | CPUs | Notes |
|---------|----------|------|------|-------|
| `pointsdb-video-clu` | `pointsdb-video-inst` | PRIMARY | 16 | POSTGRES_18, ZONAL, READY |
| `pointsdb-video-clu` | `pointsdb-video-read-pool` | READ_POOL | 16 | READY |
| `pointsdb-audio-clu` | `pointsdb-audio-inst` | PRIMARY | 8 | POSTGRES_18, ZONAL, READY |
| `pointsdb-audio-clu` | `pointsdb-audio-read-pool` | READ_POOL | 8 | READY |

### `vz-inscape-portfolio-stage`

No AlloyDB clusters as of the last inventory.

## Credentials
- Prefer **IAM database authentication** (`--auto-iam-authn`) where enabled — no stored passwords.
- For built-in users, retrieve secrets from your secret manager at run time; never hardcode or echo them.
- Read-only checks only require `SELECT`/`SHOW`/`EXPLAIN` and access to `information_schema` / `performance_schema` / `pg_stat_*`.

## PSC-only CloudSQL instances (e.g. `tvc-qa`) — Auth Proxy recipe

Some instances have **no public IP and no VPC-native private IP** — they're reachable only via a **PSC endpoint**. `cloud-sql-proxy --private-ip` fails these with `instance does not have IP of type "PRIVATE"`. In `--psc` mode the proxy dials the instance's API `dnsName` (a `*.sql.goog` name) that lives in a **private** Cloud DNS zone; if your client resolves via a public resolver you get `no such host` even though the PSC IP is routable. See [GCP/tvc-qa-psc-auth-proxy-dns-finding.md](../../GCP/tvc-qa-psc-auth-proxy-dns-finding.md) for the full write-up.

**Discover PSC facts:**
```bash
gcloud sql instances describe <instance> --project=<project> \
  --format="json(connectionName,dnsName,settings.ipConfiguration.pscConfig.pscAutoConnections)"
```

### `tvc-qa` (project `vz-inscape-portfolio-qa`, region `us-east4`)
| Fact | Value |
|------|-------|
| Connection name | `vz-inscape-portfolio-qa:us-east4:tvc-qa` |
| PSC endpoint IP | `10.235.255.244` |
| Instance `dnsName` (proxy dials this) | `0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog` |
| Public custom name → same IP | `tvc-db.qa.gcp.cognet.tv` |
| SSL mode | `ENCRYPTED_ONLY` · IAM auth: on |

**Working recipe A — Auth Proxy (needs the goog `dnsName` to resolve):**
```bash
# If your resolver can't see the private *.sql.goog zone, bridge it (temporary, laptop-local):
GOOG=0dc2f1e00504.196oni6tu0t0i.us-east4.sql.goog
echo "$(dig +short tvc-db.qa.gcp.cognet.tv | head -1)  $GOOG  # csql-proxy-temp tvc-qa" | sudo tee -a /etc/hosts

cloud-sql-proxy --psc --auto-iam-authn --port 5433 vz-inscape-portfolio-qa:us-east4:tvc-qa
# connect with NO password (proxy injects the IAM token):
psql "host=127.0.0.1 port=5433 dbname=postgres user=<you>@vizio.com sslmode=disable"

sudo sed -i '' "/# csql-proxy-temp tvc-qa/d" /etc/hosts   # cleanup
```

**Working recipe B — direct, no proxy (fastest; custom name resolves publicly):**
```bash
PGPASSWORD=$(gcloud auth print-access-token) \
  psql "host=tvc-db.qa.gcp.cognet.tv port=5432 dbname=postgres user=<you>@vizio.com sslmode=require"
```

- IAM DB username = your full email (e.g. `michael.dspain@vizio.com`) since these are `CLOUD_IAM_GROUP_USER` roles.
- Durable fix (avoids the hosts edit): have the VPN push the VPC's private `sql.goog` resolver, **or** add a TXT record on a resolvable domain (value = connection name) and use the proxy's DNS-names feature (`cloud-sql-proxy --auto-iam-authn <domain>`).
