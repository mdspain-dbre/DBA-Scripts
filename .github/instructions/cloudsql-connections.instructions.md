---
description: "CloudSQL connection reference for project vz-inscape-portfolio-dev: instance connection names, regions, engines, and Cloud SQL Auth Proxy ports. Consult before connecting to any CloudSQL MySQL/Postgres instance or running a health check / backup audit."
applyTo: "GCP/**,**/*cloudsql*,**/*CloudSQL*"
---
# CloudSQL Connection Reference — `vz-inscape-portfolio-dev`

Standard facts for connecting to CloudSQL instances in this project. Keep this table up to date; agents and prompts rely on it so they don't have to rediscover connection details every run.

## Connection conventions
- **Always connect via the Cloud SQL Auth Proxy** — never expose public IP or embed passwords.
- Connection name format: `vz-inscape-portfolio-dev:<region>:<instance>`.
- Start the proxy, then connect over `127.0.0.1:<local-port>`; tear the proxy down when finished.
  - IAM auth: `cloud-sql-proxy --auto-iam-authn --port <local-port> vz-inscape-portfolio-dev:<region>:<instance>`
  - Built-in auth: `cloud-sql-proxy --port <local-port> vz-inscape-portfolio-dev:<region>:<instance>` then `psql`/`mysql` with the DB user.
- Default local ports: **Postgres 5432**, **MySQL 3306**. If running multiple proxies at once, increment (5433, 5434, … / 3307, 3308, …) to avoid collisions.

## Instances
> Fill in the rows below. Discover live values with:
> `gcloud sql instances list --project=vz-inscape-portfolio-dev --format="table(name,databaseVersion,region,settings.availabilityType,ipAddresses[].type)"`

| Instance | Engine / Version | Region | Connection name | Local proxy port | Notes (prod?, HA?, replicas) |
|----------|------------------|--------|-----------------|------------------|------------------------------|
| _TBD_    | _e.g. POSTGRES_15_ | _us-east1_ | `vz-inscape-portfolio-dev:us-east1:<instance>` | 5432 | _fill in_ |
| _TBD_    | _e.g. MYSQL_8_0_   | _us-east1_ | `vz-inscape-portfolio-dev:us-east1:<instance>` | 3306 | _fill in_ |

## Credentials
- Prefer **IAM database authentication** (`--auto-iam-authn`) where enabled — no stored passwords.
- For built-in users, retrieve secrets from your secret manager at run time; never hardcode or echo them.
- Read-only checks only require `SELECT`/`SHOW`/`EXPLAIN` and access to `information_schema` / `performance_schema` / `pg_stat_*`.
