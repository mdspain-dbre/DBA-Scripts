#!/usr/bin/env pwsh

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-RdsToCloudSqlBackup {
    <#
    .SYNOPSIS
        Dumps a PostgreSQL database from AWS RDS, streams it to GCS, and imports it into a Cloud SQL instance.

    .DESCRIPTION
        Pipelines pg_dump | gzip | gcloud storage cp so no dump file is written to local disk.
        After upload, kicks off a Cloud SQL SQL import against the target database.

        Requires:
          - aws CLI with an active SSO session for -AwsProfile
          - gcloud CLI authenticated with rights on -GcpProjectId
          - pg_dump matching the source server's major version
          - IAM binding granting the Cloud SQL service agent
            roles/storage.objectViewer on the target GCS bucket

    .PARAMETER AwsProfile
        AWS CLI profile used to describe the source RDS instance.

    .PARAMETER AwsRegion
        AWS region of the source RDS instance.

    .PARAMETER SourceRdsInstance
        RDS DB instance identifier of the source Postgres server.

    .PARAMETER SourceDb
        Database name to dump.

    .PARAMETER SourceDbUser
        Postgres user used by pg_dump.

    .PARAMETER SourceDbPassword
        Password for SourceDbUser. Exported as PGPASSWORD only for the duration of the dump.

    .PARAMETER GcpProjectId
        GCP project that owns the target Cloud SQL instance and the GCS bucket.

    .PARAMETER TargetCloudSqlInstance
        Cloud SQL instance ID that will receive the import.

    .PARAMETER TargetDb
        Database on the Cloud SQL instance to import into (must already exist).

    .PARAMETER GcsBucket
        GCS bucket name (no gs:// prefix) that will hold the dump.

    .PARAMETER ImportAsync
        If set, starts the Cloud SQL import asynchronously and prints the operation ID.

    .PARAMETER PgDumpBin
        Full path to pg_dump. Must match the source server's major version.

    .EXAMPLE
        # QA unicorn refresh using all defaults
        Invoke-RdsToCloudSqlBackup

    .EXAMPLE
        # Kick off the Cloud SQL import in the background
        Invoke-RdsToCloudSqlBackup -ImportAsync

    .EXAMPLE
        # Override the password
        Invoke-RdsToCloudSqlBackup `
            -SourceDbPassword 'sekret'

    .EXAMPLE
        # Different source/target end-to-end
        Invoke-RdsToCloudSqlBackup `
            -AwsProfile 'Inscape Production US 1' `
            -SourceRdsInstance 'prod-rds-other-pg18' `
            -SourceDb 'otherdb' `
            -TargetCloudSqlInstance 'another-cloudsql' `
            -TargetDb 'otherdb' `
            -GcsBucket 'another-backup-bucket'
    #>
    [CmdletBinding()]
    param(
        [string]$AwsProfile = 'inscape-production-us-1-inscape-aws-ops',
        [string]$AwsRegion = 'us-east-1',
        [string]$SourceRdsInstance = 'prod-rds-unicorn-qa-pg18',
        [string]$SourceDb = 'unicorn',
        [string]$SourceDbUser = 'root',
        [string]$SourceDbPassword = 'KVV0hjhRf&zGXK9j',
        [string]$GcpProjectId = 'vz-inscape-portfolio-qa',
        [string]$TargetCloudSqlInstance = 'admin-portal-db',
        [string]$TargetDb = 'unicorn',
        [string]$GcsBucket = 'portaldb-backup',
        [switch]$ImportAsync,
        [string]$PgDumpBin = '/opt/homebrew/opt/postgresql@18/bin/pg_dump'
    )

    Write-Host 'Resolving source RDS endpoint'
    $rdsOutput = & aws --profile $AwsProfile --region $AwsRegion rds describe-db-instances `
        --db-instance-identifier $SourceRdsInstance `
        --query 'DBInstances[0].Endpoint.[Address,Port]' --output text
    if ($LASTEXITCODE -ne 0) { throw "aws rds describe-db-instances failed (exit $LASTEXITCODE)" }

    $rdsParts = ($rdsOutput -split '\s+') | Where-Object { $_ }
    if ($rdsParts.Count -lt 2) {
        throw "Unexpected RDS endpoint output: $rdsOutput"
    }
    $sourceHost = $rdsParts[0]
    $sourcePort = $rdsParts[1]
    Write-Host "Source RDS: ${sourceHost}:${sourcePort}"

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $gcsUri = "gs://$($GcsBucket.TrimEnd('/'))/${SourceDb}_$timestamp.sql.gz"

    Write-Host "Streaming pg_dump | gzip | gcloud storage cp -> $gcsUri"

    $oldPassword = $env:PGPASSWORD
    $oldSslMode = $env:PGSSLMODE
    $env:PGPASSWORD = $SourceDbPassword
    $env:PGSSLMODE = 'require'
    try {
        # Use `set -o pipefail` semantics via bash so a pg_dump failure kills
        # the pipeline and returns a non-zero exit code (PowerShell pipelines
        # only surface the *last* command's exit code, which masks pg_dump errors).
        $pgDumpArgs = @(
            "--host=$sourceHost",
            "--port=$sourcePort",
            "--username=$SourceDbUser",
            "--dbname=$SourceDb",
            '--format=plain',
            '--encoding=UTF8',
            '--no-owner',
            '--no-privileges',
            '--quote-all-identifiers'
        ) -join ' '

        $bashCmd = "set -euo pipefail; '$PgDumpBin' $pgDumpArgs | gzip -c | gcloud --project '$GcpProjectId' storage cp - '$gcsUri'"
        & /bin/bash -c $bashCmd
        if ($LASTEXITCODE -ne 0) { throw "Dump/upload pipeline failed (exit $LASTEXITCODE)" }
    }
    finally {
        $env:PGPASSWORD = $oldPassword
        $env:PGSSLMODE = $oldSslMode
    }

    Write-Host 'Verifying uploaded object'
    & gcloud --project $GcpProjectId storage ls -l $gcsUri
    if ($LASTEXITCODE -ne 0) { throw "gcloud storage ls failed (exit $LASTEXITCODE)" }

    Write-Host 'Starting Cloud SQL import'
    if ($ImportAsync) {
        $operationId = & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
            --database=$TargetDb --async --format='value(name)'
        if ($LASTEXITCODE -ne 0) { throw "gcloud sql import (async) failed (exit $LASTEXITCODE)" }
        Write-Host "Import started asynchronously. Operation: $operationId"
        Write-Host "Track with: gcloud --project $GcpProjectId sql operations describe $operationId"
    }
    else {
        & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
            --database=$TargetDb --quiet
        if ($LASTEXITCODE -ne 0) { throw "gcloud sql import failed (exit $LASTEXITCODE)" }
        Write-Host 'Import completed successfully'
    }

    Write-Host 'Done'
    Write-Host "GCS object: $gcsUri"
}



Invoke-RdsToCloudSqlBackup -GcsBucket 'portaldb-backup' -SourceDbPassword 'KVV0hjhRf&zGXK9j' -SourceDbUser 'root'