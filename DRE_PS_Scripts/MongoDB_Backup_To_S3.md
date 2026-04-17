# MongoDB Backup to S3 via SSH

## Overview

This document describes the automated MongoDB backup process that streams database backups directly to AWS S3 using `mongodump` over an SSH connection. The solution consists of two components:

| Component         | File                                                                     | Purpose                                                                   |
| ----------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| PowerShell Script | `DRE_PS_Scripts/CS_MongoBackupToS3_SSH.ps1`                              | Connects to MongoDB via SSH, runs `mongodump`, and streams archives to S3 |
| SQL Agent Job     | `DBStatsCollectors/DBStatsDBSchema/Agent_Job_CS_MongoBackupToS3_SSH.sql` | Schedules the PowerShell script to run daily via SQL Server Agent         |

---

## Architecture

```
DRE-Jumpbox (SQL Agent)
  │
  │  SSH (Posh-SSH module, key-based auth)
  ▼
MongoDB Server (10.121.162.210)
  │
  │  mongodump --archive --gzip | aws s3 cp -
  ▼
AWS S3 (prod-sql-1-backups/mongobackups/)
```

- The script runs on the **DRE-Jumpbox** and establishes an SSH session to the MongoDB server.
- `mongodump` and `aws s3 cp` execute **on the MongoDB server** — the backup is piped directly to S3 without touching disk on either machine.
- AWS authentication uses the **IAM instance role** attached to the MongoDB server (no stored credentials).

---

## PowerShell Script — CS_MongoBackupToS3_SSH.ps1

### Parameters

| Parameter   | Default                     | Description                                |
| ----------- | --------------------------- | ------------------------------------------ |
| `MongoHost` | `10.121.162.210`            | IP/hostname of the MongoDB server          |
| `KeyFile`   | `D:\SSH_Keys\PS_SSHKey.pem` | Path to the SSH private key on the Jumpbox |
| `SSHUser`   | `ubuntu`                    | SSH username on the MongoDB server         |
| `S3Bucket`  | `prod-sql-1-backups`        | Target S3 bucket                           |
| `S3Prefix`  | `mongobackups`              | S3 key prefix                              |
| `Databases` | *(see below)*               | Array of database names to back up         |

### Default Databases

The following databases are backed up by default:

- `admin`
- `config`
- `testing42`
- `test44`
- `ExtruderStateTest`
- `ImageWarehouseProd`
- `ImageWarehouseTest`
- `WarehourseMirrorTest`
- `HumanInteractionQueuesProd`

### S3 Output Path Structure

Each backup is stored at:

```
s3://prod-sql-1-backups/mongobackups/<database>/<timestamp>/<database>_<timestamp>.archive.gz
```

Example:

```
s3://prod-sql-1-backups/mongobackups/ExtruderStateTest/20260403_000000/ExtruderStateTest_20260403_000000.archive.gz
```

### Execution Flow

1. Generates a timestamp (`yyyyMMdd_HHmmss`).
2. Establishes an SSH session to the MongoDB server using key-based authentication.
3. If no databases are specified, discovers all databases via `mongo --eval` (currently overridden by the hardcoded default list).
4. Configures AWS CLI on the remote host for multi-threaded multipart uploads:
   - `max_concurrent_requests = 20`
   - `multipart_chunksize = 64MB`
   - `multipart_threshold = 64MB`
5. For each database, runs `mongodump --archive --gzip | aws s3 cp - <s3_key>`.
6. Logs success or failure per database.
7. Closes the SSH session in the `finally` block.

### Timeouts

- **Database discovery**: 60 seconds
- **Per-database backup**: 43,200 seconds (12 hours)

### Prerequisites

| Requirement                       | Location                      |
| --------------------------------- | ----------------------------- |
| `Posh-SSH` PowerShell module      | DRE-Jumpbox                   |
| SSH private key (`PS_SSHKey.pem`) | `D:\SSH_Keys\` on DRE-Jumpbox |
| `mongodump`                       | MongoDB server                |
| AWS CLI (configured via IAM role) | MongoDB server                |
| S3 bucket `prod-sql-1-backups`    | AWS                           |

### Manual Execution

```powershell
# Back up all default databases
.\CS_MongoBackupToS3_SSH.ps1

# Back up a single database
.\CS_MongoBackupToS3_SSH.ps1 -Databases @("ExtruderStateTest")

# Back up multiple specific databases
.\CS_MongoBackupToS3_SSH.ps1 -Databases @("ExtruderStateTest", "ImageWarehouseProd")
```

---

## SQL Agent Job — Agent_Job_CS_MongoBackupToS3_SSH.sql

### Job Configuration

| Setting  | Value                    |
| -------- | ------------------------ |
| Job Name | `CS_MongoBackupToS3_SSH` |
| Category | `DBStatsCollector`       |
| Owner    | `sa`                     |
| Enabled  | Yes                      |
| Proxy    | `PS_Connect`             |

### Schedule

| Setting    | Value                  |
| ---------- | ---------------------- |
| Name       | `Daily MongoDB Backup` |
| Frequency  | Daily (every day)      |
| Start Time | 12:00 AM (midnight)    |
| Start Date | April 2, 2026          |

### Job Step

| Setting    | Value                                                           |
| ---------- | --------------------------------------------------------------- |
| Step Name  | `Execute Powershell`                                            |
| Subsystem  | `CmdExec`                                                       |
| Command    | `powershell.exe "D:\DRE_PS_Scripts\CS_MongoBackupToS3_SSH.ps1"` |
| Proxy      | `PS_Connect`                                                    |
| On Success | Quit with success                                               |
| On Failure | Quit with failure                                               |

---

## Troubleshooting

### Timeout Errors

If a backup times out (`Command '...' has timed out`), the per-database timeout is currently set to 12 hours (43,200 seconds). For extremely large databases, this can be increased via the `-TimeOut` parameter on the `Invoke-SSHCommand` call in the script.

### SSH Connection Failures

- Verify the SSH key exists at `D:\SSH_Keys\PS_SSHKey.pem` on the Jumpbox.
- Confirm network connectivity from the Jumpbox to `10.121.162.210` on port 22.
- Check that the `ubuntu` user is authorized for key-based SSH login.

### S3 Upload Failures

- Verify the IAM instance role on the MongoDB server has `s3:PutObject` permission to `prod-sql-1-backups`.
- Check AWS CLI is installed and functional on the MongoDB server (`aws --version`).

### Restoring a Backup

```bash
# Download and restore
aws s3 cp s3://prod-sql-1-backups/mongobackups/<db>/<timestamp>/<file>.archive.gz - | mongorestore --archive --gzip

# Restore to a different database name
aws s3 cp s3://prod-sql-1-backups/mongobackups/<db>/<timestamp>/<file>.archive.gz - | mongorestore --archive --gzip --nsFrom="<original_db>.*" --nsTo="<new_db>.*"
```
