# AWS Aurora → GCP Cloud SQL Mapping

Conversion reference for `tvc-production` (AWS Aurora PostgreSQL, account `788724168120`)
ported to Cloud SQL for PostgreSQL in GCP project `dre-sandbox-471618`.

| AWS Aurora                                 | Cloud SQL equivalent                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------- |
| 2-node Aurora cluster (writer + reader)    | HA primary (REGIONAL: active+standby) + 1 read replica                    |
| `db.r6i.2xlarge` (8 vCPU, 64 GB)           | `db-custom-8-65536`                                                       |
| Aurora PostgreSQL 12.22                    | `POSTGRES_12`                                                             |
| `tvlocation` database, `root` user         | `google_sql_database` + `google_sql_user`                                 |
| KMS storage encryption                     | `encryption_key_name` (CMEK, optional — Google-managed by default)        |
| Backup retention 7, window 08:33–09:03 UTC | `backup_configuration` retained_backups=7, start_time=08:33, PITR enabled |
| Maintenance fri:07:12                      | `maintenance_window` day=5, hour=7                                        |
| Master password in Secrets Manager         | `random_password` resource (push to Secret Manager separately)            |
| VPC SGs / subnet group                     | `private_network` (PSA) — set `var.private_network`                       |

## Notes

- Cloud SQL HA standby is **not readable** — use the read replica for read traffic.
- Cloud SQL replicas are always zonal; placed in `var.replica_zone`.
- Postgres 12 is end-of-life — consider upgrading to `POSTGRES_15` or `POSTGRES_16` on a fresh build.
- `db-custom-8-65536` with HA + replica is roughly $700+/month; verify before applying in a sandbox project.
