# RDS Instance: vueuserprod1

## General

| Property                | Value                                                         |
|-------------------------|---------------------------------------------------------------|
| **Endpoint**            | `vueuserprod1.cha2gmuppdx1.us-west-2.rds.amazonaws.com:1433`  |
| **Engine**              | SQL Server Standard Edition (`sqlserver-se`)                  |
| **Engine Version**      | 13.00.6430.49.v1 (SQL Server 2016 SP3)                        |
| **Instance Class**      | `db.m5.2xlarge`                                               |
| **Status**              | Available                                                     |
| **Created**             | 2016-09-06                                                    |
| **Region / AZ**         | us-west-2c (secondary: us-west-2a)                            |
| **Multi-AZ**            | Yes                                                           |
| **Publicly Accessible** | No                                                            |
| **Network**             | IPv4 only                                                     |

## Storage

| Property                 | Value                      |
|--------------------------|----------------------------|
| **Storage Type**         | io1 (Provisioned IOPS SSD) |
| **Allocated Storage**    | 200 GB                     |
| **Provisioned IOPS**     | 5,000                      |
| **Storage Encrypted**    | No                         |
| **Dedicated Log Volume** | No                         |

## Backup & Recovery

| Property                       | Value                                    |
|--------------------------------|------------------------------------------|
| **Automated Backup Retention** | 7 days                                   |
| **Backup Window**              | 10:52–11:22 UTC daily                    |
| **Backup Target**              | Region                                   |
| **Latest Restorable Time**     | 2026-04-13 19:24 UTC                     |
| **S3 Backup/Restore**          | Enabled (IAM role: `RDSS3BackupRestore`) |
| **Copy Tags to Snapshot**      | No                                       |
| **Deletion Protection**        | Yes                                      |

### Recent Automated Snapshots

| Snapshot                           | Created    | Size   |
|------------------------------------|------------|--------|
| rds:vueuserprod1-2026-04-13-11-01  | 2026-04-13 | 200 GB |
| rds:vueuserprod1-2026-04-12-11-01  | 2026-04-12 | 200 GB |
| rds:vueuserprod1-2026-04-11-11-01  | 2026-04-11 | 200 GB |

## Authentication & Access

| Property                    | Value                                  |
|-----------------------------|----------------------------------------|
| **Master Username**         | `vizio`                                |
| **IAM DB Auth**             | Disabled                               |
| **VPC**                     | vpc-ceeb12aa                           |
| **Security Group**          | sg-18f06f7f                            |
| **Active Directory Domain** | `RDS.seadata.vizio.com` (d-9267259e06) |
| **Character Set**           | SQL_Latin1_General_CP1_CI_AS           |

## Monitoring & Performance

| Property                 | Value                     |
|--------------------------|---------------------------|
| **Enhanced Monitoring**  | Every 15 seconds          |
| **Performance Insights** | Enabled (7-day retention) |
| **Database Insights**    | Standard                  |

## Maintenance

| Property                        | Value                                    |
|---------------------------------|------------------------------------------|
| **Maintenance Window**          | Wednesday 12:53–13:23 UTC                |
| **Auto Minor Version Upgrade**  | Disabled                                 |
| **License Model**               | License Included                         |
| **Parameter Group**             | `default.sqlserver-se-13.0` (in-sync)    |
| **Option Group**                | `vueuserprod1-sqlserver-se-13` (in-sync) |

## Certificate

| Property          | Value             |
|-------------------|-------------------|
| **CA Identifier** | rds-ca-rsa2048-g1 |
| **Valid Until**    | 2027-08-14        |

## Tags

| Key                            | Value        |
|--------------------------------|--------------|
| Name                           | vueuserprod1 |
| Service                        | VueServices  |
| OPP-5465_db_cost_resource_name | vueuserprod1 |

## SQL Server Native Backups to S3

### Overview

In addition to the automated RDS snapshots (see Backup & Recovery above), this instance uses
**SQL Server native backup/restore** via the `SQLSERVER_BACKUP_RESTORE` option to write `.bak`
files directly to an S3 bucket. This enables granular, database-level restores and cross-account
portability that RDS automated snapshots do not support.

### Option Group Configuration

| Property           | Value                                                   |
|--------------------|---------------------------------------------------------|
| **Option Group**   | `vueuserprod1-sqlserver-se-13`                          |
| **Option Enabled** | `SQLSERVER_BACKUP_RESTORE`                              |
| **IAM Role**       | `arn:aws:iam::980673749644:role/RDSS3BackupRestore`     |
| **S3 Bucket**      | `content-services-windows-mongo-backups`                |
| **S3 Backup Path** | `arn:aws:s3:::content-services-windows-mongo-backups/VueProdUserDB/FULL/<DatabaseName>/` |

### SQL Agent Job: RDS_NativeFullBackup

The SQL Agent job `RDS_NativeFullBackup` calls the stored procedure `[DBA].[dbo].[SqlNativeBackup]`
which iterates through all user databases and backs each one up to S3 using striped (multi-file)
backups for parallelism and faster throughput.

**Job Details:**

| Property               | Value                                                       |
|------------------------|-------------------------------------------------------------|
| **Job Name**           | RDS_NativeFullBackup                                        |
| **Stored Procedure**   | `[DBA].[dbo].[SqlNativeBackup]`                             |
| **Backup Type**        | FULL                                                        |
| **Number of Stripes**  | 10 files per database                                       |
| **Overwrite Existing** | Yes (`@overwrite_S3_backup_file=1`)                         |
| **Databases Included** | All user databases (`database_id > 4`, excludes `rdsadmin`) |

### How It Works

1. The procedure `[dbo].[SqlNativeBackup]` opens a cursor over all user databases.
2. For each database, it builds an S3 ARN path using the pattern:
   ```
   arn:aws:s3:::content-services-windows-mongo-backups/VueProdUserDB/FULL/<DatabaseName>/<DatabaseName>_<dd-MM-yyyy-hhmm>*
   ```
3. The `*` wildcard at the end of the ARN tells RDS to create striped backup files. RDS
   automatically appends `_01-of-10`, `_02-of-10`, etc. to each stripe filename.
4. It calls `msdb.dbo.rds_backup_database` with `@number_of_files=10` to split the backup
   across 10 parallel streams for faster upload to S3.

### Example Execution

```sql
-- Execute backups (production)
EXEC [DBA].[dbo].[SqlNativeBackup] @print = 0;

-- Print the backup commands without executing (dry run)
EXEC [DBA].[dbo].[SqlNativeBackup] @print = 1;
```

### Example Generated Backup Command

```sql
EXEC msdb.dbo.rds_backup_database
    @source_db_name='Harmony',
    @s3_arn_to_backup_to='arn:aws:s3:::content-services-windows-mongo-backups/VueProdUserDB/FULL/UserData/UserData_04-09-2026-0748-49*',
    @type='FULL',
    @overwrite_S3_backup_file=1,
    @number_of_files=10;
```

### S3 Folder Structure

```
content-services-windows-mongo-backups/
├── MongoBackups/
└── VueProdUserDB/
    └── FULL/
        ├── Bootstrap/
        ├── DBA/
        ├── DeviceData/
        ├── GlobalData/
        ├── Stage-PushNotification/
        └── UserData/
            ├── UserData_04-09-2026-0748-49_01-of-10.bak
            ├── UserData_04-09-2026-0748-49_02-of-10.bak
            ├── ...
            └── UserData_04-09-2026-0748-49_10-of-10.bak
```

### Restoring from S3 Striped Backups

To restore a striped backup, use a wildcard `*` at the end of the S3 ARN prefix:

```sql
EXEC msdb.dbo.rds_restore_database
    @restore_db_name='Harmony',
    @s3_arn_to_restore_from='arn:aws:s3:::content-services-windows-mongo-backups/VueProdUserDB/FULL/UserData/UserData_04-09-2026-0748-49*';
```

> **Note:** Do NOT use comma-separated ARNs or `@number_of_files` for restore — use the
> wildcard `*` pattern which lets RDS auto-discover all stripe files.

### Monitoring Backup Status

```sql
-- Check status of recent backup/restore tasks
SELECT TOP 10 *
FROM msdb.dbo.rds_fn_task_status(NULL, 0)
ORDER BY task_id DESC;
```

### Known Issue

Native backups will abort if they overlap with the RDS automated backup window (10:52–11:22 UTC).
Schedule the SQL Agent job to avoid this window. If a collision occurs, the task logs:
`Aborting native backup because there is an RDS automated backup in progress.`
