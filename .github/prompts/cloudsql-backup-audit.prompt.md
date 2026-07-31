---
description: "Focused CloudSQL backup & point-in-time-recovery (PITR) compliance report for a GCP project. Use for: 'audit my cloudsql backups', 'are backups and PITR enabled', 'backup compliance report', 'check retention windows'."
name: "CloudSQL Backup Audit"
agent: "DB Fleet Health Check"
argument-hint: "Optional project ID (defaults to vz-inscape-portfolio-dev) or a single instance name"
---
Produce a **backup & point-in-time-recovery (PITR) compliance report** for every CloudSQL MySQL and PostgreSQL instance in the project (default `vz-inscape-portfolio-dev`, or the project/instance named in my request).

This is a **read-only** audit — do not enable, change, or delete any backup, instance, or database. Only run `gcloud sql ... list/describe`, `gcloud sql backups list`, and read-only queries.

For each instance, gather from `gcloud sql instances describe <name> --project=<project> --format=json` and `gcloud sql backups list --instance=<name> --project=<project>`:
- **Automated backups**: `settings.backupConfiguration.enabled` and the configured start time / backup window.
- **PITR**: `pointInTimeRecoveryEnabled` (Postgres) / `binaryLogEnabled` (MySQL), and `transactionLogRetentionDays`.
- **Retention**: `backupRetentionSettings.retainedBackups` (count) and retention unit.
- **Recency**: timestamp and status of the most recent successful backup; flag any instance whose newest successful backup is older than its backup interval, or where the latest backup FAILED.
- **Cross-region / DR**: whether backups have a configured secondary location, and whether a cross-region read replica exists.
- **Location**: backup storage location vs instance region.

## Compliance thresholds (flag as ⚠️/❌ when not met)
- Automated backups **enabled** — ❌ if disabled.
- PITR **enabled** — ⚠️ if disabled (❌ for production-named instances).
- Retention **≥ 7 days / ≥ 7 retained backups** — ⚠️ if lower.
- A **successful** backup within the last backup interval — ❌ if the most recent backup failed or is stale.

## Output
Lead with a one-line verdict (e.g. "8 instances — 6 compliant, 1 warning, 1 critical"). Then:

| Instance | Engine | Auto Backups | PITR | Retention | Last Successful Backup | DR/Cross-region | Status |
|----------|--------|--------------|------|-----------|------------------------|-----------------|--------|

Use ✅ / ⚠️ / ❌. Follow with **Remediation notes** ordered by severity — for each gap, name the instance and give the exact `gcloud sql instances patch ...` command the operator *could* run (as text only; do not execute it). Note any instance where backup data could not be read and why.
