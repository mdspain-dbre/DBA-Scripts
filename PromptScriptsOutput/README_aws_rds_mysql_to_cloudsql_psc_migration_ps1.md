# AWS RDS MySQL to Cloud SQL (PSC) - PowerShell Run Guide

This guide documents how to run:

- ./aws_rds_mysql_to_cloudsql_psc_migration.ps1

in staged mode for a controlled migration from AWS RDS MySQL to Google Cloud SQL MySQL using Private Service Connect (PSC).

## Script Location

- ./aws_rds_mysql_to_cloudsql_psc_migration.ps1

## Prerequisites

Ensure these CLIs are installed and authenticated before running any stage:

1. aws CLI (AWS SSO/session valid for the selected profile)
2. gcloud CLI (active account has required IAM in target project)
3. mysql client
4. PowerShell 7+ (pwsh)

## Important Safety Notes

1. Source operations are read-only (mysqldump).
2. Cleanup is destructive and requires explicit confirmation prompts.
3. Do not place plaintext secrets in command history when possible.
4. Prefer RDS_PASSWORD_PARAM over RDS_PASSWORD for safer secret retrieval.

## Environment Variables

Set these before running (example shown for zsh/bash shell):

```bash
export AWS_PROFILE='inscape-production-us-1-inscape-aws-ops'
export AWS_REGION='us-east-1'

export RDS_ENDPOINT='prod-rds-auxdb-qa-80-20240808.cujpo2r0mujo.us-east-1.rds.amazonaws.com'
export RDS_PORT='3306'
export RDS_USER='master'

# Choose ONE:
# Option A: plaintext (less safe)
# export RDS_PASSWORD='REPLACE_ME'
# Option B: SSM parameter path (preferred)
export RDS_PASSWORD_PARAM='/path/to/secure/rds/password'

export GCP_PROJECT_ID='vz-inscape-portfolio-dev'
export GCP_REGION='us-west1'
export CLOUDSQL_INSTANCE='auxdb-qa-dre-test2'
export CLOUDSQL_DB_VERSION='MYSQL_8_0'
export CLOUDSQL_TIER='db-custom-2-7680'
export CLOUDSQL_DISK_SIZE_GB='300'
export CLOUDSQL_ROOT_PASSWORD='REPLACE_ME'
export ALLOWED_PSC_PROJECTS='vz-inscape-portfolio-dev,vz-inscape-dev'

export SOURCE_CLIENT_SG_ID='sg-750d9c02'

# Optional overrides (if you want to pin networking/resources)
# export DUMP_VPC_ID='vpc-xxxx'
# export DUMP_SUBNET_ID='subnet-xxxx'
# export DUMP_SG_ID='sg-xxxx'
# export S3_BUCKET='custom-bucket-name'
# export GCS_BUCKET='gs://custom-bucket-name'
```

On PowerShell instead of zsh/bash, use $env:NAME = 'value'.

## Stage Execution Order

Run from the PromptScriptsOutput directory:

```bash
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 preflight
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 inventory-source
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 create-target
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 stage-buckets
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 launch-dump-host
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 start-dump
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 transfer-to-gcs
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 patch-flag
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 start-import
```

After import finishes:

```bash
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 create-master-user
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 verify
```

## Optional One-Shot

This runs all stages up through async import start (not cleanup):

```bash
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 run-all
```

## Monitoring and Artifacts

Each run creates a timestamped folder under PromptScriptsOutput:

- migration_run_YYYYMMDD_HHMMSS/

Key files:

1. resource_state.log
2. migration.log
3. import_watch.log (created by start-import)
4. transfer_s3_to_gcs.log (created by transfer-to-gcs)
5. verify_notes.txt (created by verify)

## Cleanup (Destructive)

Only run after you confirm migration verification is complete.

```bash
pwsh -NoProfile -File ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 cleanup
```

Cleanup stage prompts twice and can:

1. Terminate dump EC2
2. Remove IAM role/profile created for dump host
3. Delete S3 and GCS dump objects

It does not delete the Cloud SQL instance.

## Troubleshooting Quick Notes

1. If preflight fails for credentials, re-authenticate AWS SSO and gcloud.
2. If launch-dump-host fails subnet checks, provide DUMP_SUBNET_ID in same VPC/AZ as RDS.
3. If transfer-to-gcs waits indefinitely, verify dump upload is still in progress or stalled.
4. If start-import fails access to GCS object, re-run stage-buckets to re-apply IAM binding.
5. If create-master-user says user exists, this is expected idempotent behavior.
