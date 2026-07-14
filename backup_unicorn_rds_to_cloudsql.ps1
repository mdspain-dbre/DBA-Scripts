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

    .PARAMETER GcsObjectUri
        Optional override used only when -ImportOnly 1 is also passed. Points at an
        existing gs:// object to import instead of auto-discovering the newest upload.
        Ignored on a full run. Example:
        Invoke-RdsToCloudSqlBackup -ImportOnly 1 -GcsObjectUri 'gs://portaldb-backup-dre/unicorn_20260713_142852.sql.gz'

    .PARAMETER ImportOnly
        0 (default) = full run (dump + upload + import).
        1 = skip the pg_dump/upload phase and only run the Cloud SQL import.
        When 1 and -GcsObjectUri is not supplied, the newest
        gs://<GcsBucket>/<SourceDb>_*.sql.gz object is auto-selected and printed.

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
        # Import-only: reuse the newest dump already in the bucket
        # (skips pg_dump/upload; auto-selects the latest gs://<bucket>/<db>_*.sql.gz)
        Invoke-RdsToCloudSqlBackup -ImportOnly 1 -GcsBucket 'portaldb-backup-dre'

    .EXAMPLE
        # Import-only against a specific object
        Invoke-RdsToCloudSqlBackup `
            -ImportOnly 1 `
            -GcsObjectUri 'gs://portaldb-backup-dre/unicorn_20260713_191539.sql.gz'

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
        [string]$GcsObjectUri,
        [ValidateSet(0, 1)]
        [int]$ImportOnly = 0,
        [string]$PgDumpBin = '/opt/homebrew/opt/postgresql@18/bin/pg_dump'
    )

    # =========================================================================
    # SECTION 1: Resolve $gcsUri (import-only auto-discover OR full dump+upload)
    # =========================================================================
    if ($ImportOnly -eq 1) {
        # --- Branch A: Import-only mode -------------------------------------
        # Skip RDS lookup, sizing, dump, upload. Straight to import.
        if (-not $GcsObjectUri) {
            # Auto-discover the newest dump in the bucket for this SourceDb.
            $bucketPrefix = "gs://$($GcsBucket.TrimEnd('/'))"
            $globUri = "$bucketPrefix/${SourceDb}_*.sql.gz"
            Write-Host "ImportOnly=1: searching $globUri for the most recent upload"
            $listing = & gcloud --project $GcpProjectId storage ls $globUri 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $listing) {
                throw "No objects matched $globUri. Pass -GcsObjectUri explicitly."
            } # end if (gcloud ls failed / no results)
            # Filenames embed yyyyMMdd_HHmmss, so lexicographic sort == chronological.
            # Use Select-Object -Last 1 so a single-line result is treated as one item
            # (indexing [-1] on a scalar string returns the last CHARACTER, not the string).
            $GcsObjectUri = $listing | Where-Object { $_ } | Sort-Object | Select-Object -Last 1
            Write-Host "Auto-selected latest upload: $GcsObjectUri"
        } # end if (-not $GcsObjectUri) -- auto-discovery

        if ($GcsObjectUri -notmatch '^gs://') {
            throw "GcsObjectUri must start with gs:// (got: $GcsObjectUri)"
        } # end if (GcsObjectUri scheme validation)
        $gcsUri = $GcsObjectUri
        Write-Host "Import-only mode: skipping pg_dump/upload. Using existing object: $gcsUri"
    } # end Branch A: ImportOnly
    else {
        # --- Branch B: Full run (dump + upload) -----------------------------
        Write-Host 'Resolving source RDS endpoint'
        $rdsOutput = & aws --profile $AwsProfile --region $AwsRegion rds describe-db-instances `
            --db-instance-identifier $SourceRdsInstance `
            --query 'DBInstances[0].Endpoint.[Address,Port]' --output text
        if ($LASTEXITCODE -ne 0) { throw "aws rds describe-db-instances failed (exit $LASTEXITCODE)" }

        $rdsParts = ($rdsOutput -split '\s+') | Where-Object { $_ }
        if ($rdsParts.Count -lt 2) {
            throw "Unexpected RDS endpoint output: $rdsOutput"
        } # end if (RDS endpoint parse guard)
        $sourceHost = $rdsParts[0]
        $sourcePort = $rdsParts[1]
        Write-Host "Source RDS: ${sourceHost}:${sourcePort}"

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $gcsUri = "gs://$($GcsBucket.TrimEnd('/'))/${SourceDb}_$timestamp.sql.gz"

        # Prereq: pv (pipe viewer) for progress. Fail fast with a clear hint.
        if (-not (Get-Command pv -ErrorAction SilentlyContinue)) {
            throw "pv is required for progress output. Install with: brew install pv"
        } # end if (pv prereq)

        # Prereq: pigz (parallel gzip). Much faster than gzip on multi-core hosts.
        if (-not (Get-Command pigz -ErrorAction SilentlyContinue)) {
            throw "pigz is required for parallel compression. Install with: brew install pigz"
        } # end if (pigz prereq)

        # Derive psql from the pg_dump path so versions match.
        $psqlBin = Join-Path (Split-Path $PgDumpBin) 'psql'
        if (-not (Test-Path $psqlBin)) {
            throw "psql not found at $psqlBin (needed to size the source DB)"
        } # end if (psql prereq)

        $oldPassword = $env:PGPASSWORD
        $oldSslMode = $env:PGSSLMODE
        $env:PGPASSWORD = $SourceDbPassword
        $env:PGSSLMODE = 'require'
        try {
            # --- Dump/upload pipeline (runs with PGPASSWORD/PGSSLMODE set) --
            # Ask the source how big the database is (uncompressed on-disk bytes).
            # This is an upper bound for the raw pg_dump stream — good enough for pv -s
            # to render a % / ETA. Wrapped so a failure just disables the size hint.
            $rawSizeBytes = $null
            $sizePretty   = $null
            try {
                $sizeText = & $psqlBin --host=$sourceHost --port=$sourcePort `
                    --username=$SourceDbUser --dbname=$SourceDb `
                    -Atqc "SELECT pg_database_size('$SourceDb')"
                if ($LASTEXITCODE -eq 0 -and $sizeText -match '^\d+$') {
                    $rawSizeBytes = [int64]$sizeText
                    $sizePretty = & $psqlBin --host=$sourceHost --port=$sourcePort `
                        --username=$SourceDbUser --dbname=$SourceDb `
                        -Atqc "SELECT pg_size_pretty(pg_database_size('$SourceDb'))"
                    Write-Host "Source DB size: $sizePretty ($rawSizeBytes bytes)"
                } else {
                    Write-Warning "Could not read source DB size; pv will run without a total."
                } # end if/else (pg_database_size result check)
            } catch {
                Write-Warning "Sizing query failed: $_. pv will run without a total."
            } # end try/catch (source DB sizing)

            Write-Host "Streaming pg_dump | pv | pigz -1 | pv | gcloud storage cp -> $gcsUri"

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
                '--quote-all-identifiers',
                '--verbose'
            ) -join ' '

            # First pv sits on the raw dump stream so we get bytes-done / total and % vs pg_database_size.
            # Second pv sits on the compressed stream to show upload throughput to GCS.
            # Use line-per-tick format (`-F ... \n` + `-i 2`) so PowerShell hosts that
            # buffer stderr per line still surface progress every 2 seconds.
            # Total label is embedded as a literal string so users see "3.21GiB / 42 GB".
            $totalLabel = if ($sizePretty) { $sizePretty } elseif ($rawSizeBytes) { "$rawSizeBytes bytes" } else { $null }

            $pvDump = if ($rawSizeBytes) {
                "pv -p -f -i 2 -F 'dump: %b / $totalLabel %p %r ETA %e\n' -s $rawSizeBytes"
            } else {
                "pv -f -i 2 -F 'dump: %b %r\n'"
            } # end if/else ($pvDump format selection)
            $pvGz = "pv -f -i 2 -F 'gz:   %b (compressed) %r\n'"

            # pigz -1 = fastest compression, all cores. Larger than default -6 but usually a net win
            # because compression (not network) is the bottleneck when streaming to GCS.
            $bashCmd = "set -euo pipefail; '$PgDumpBin' $pgDumpArgs | $pvDump | pigz -1 -c | $pvGz | gcloud --project '$GcpProjectId' storage cp - '$gcsUri'"
            & /bin/bash -c $bashCmd
            if ($LASTEXITCODE -ne 0) { throw "Dump/upload pipeline failed (exit $LASTEXITCODE)" }
        }
        finally {
            # Restore PGPASSWORD/PGSSLMODE regardless of dump/upload outcome.
            $env:PGPASSWORD = $oldPassword
            $env:PGSSLMODE = $oldSslMode
        } # end try/finally (PG env vars scoped to dump/upload)
    } # end Branch B: full run (dump + upload)

    # =========================================================================
    # SECTION 2: Verify uploaded object (runs in both branches)
    # =========================================================================
    Write-Host 'Verifying uploaded object'
    & gcloud --project $GcpProjectId storage ls -l $gcsUri
    if ($LASTEXITCODE -ne 0) { throw "gcloud storage ls failed (exit $LASTEXITCODE)" }

    # =========================================================================
    # SECTION 3: Cloud SQL import (runs in both branches; async vs sync)
    # =========================================================================
    Write-Host 'Starting Cloud SQL import'
    if ($ImportAsync) {
        # --- Async: kick off the import and return the operation ID ---------
        $operationId = & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
            --database=$TargetDb --async --format='value(name)'
        if ($LASTEXITCODE -ne 0) { throw "gcloud sql import (async) failed (exit $LASTEXITCODE)" }
        Write-Host "Import started asynchronously. Operation: $operationId"
        Write-Host "Track with: gcloud --project $GcpProjectId sql operations describe $operationId"
    } # end if $ImportAsync (async import branch)
    else {
        # --- Sync: block until the import completes -------------------------
        & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
            --database=$TargetDb --quiet
        if ($LASTEXITCODE -ne 0) { throw "gcloud sql import failed (exit $LASTEXITCODE)" }
        Write-Host 'Import completed successfully'
    } # end else (sync import branch)

    Write-Host 'Done'
    Write-Host "GCS object: $gcsUri"
} # end function Invoke-RdsToCloudSqlBackup



# Full run (dump + upload + import):
# Invoke-RdsToCloudSqlBackup -GcsBucket 'portaldb-backup' -SourceDbPassword 'KVV0hjhRf&zGXK9j' -SourceDbUser 'root'

# Import-only (auto-picks the newest dump in the bucket):
##Invoke-RdsToCloudSqlBackup -ImportOnly 1 -GcsBucket 'portaldb-backup'

# Import-only against a specific object:
# Invoke-RdsToCloudSqlBackup -GcsObjectUri 'gs://portaldb-backup-dre/unicorn_20260713_191539.sql.gz'


Invoke-RdsToCloudSqlBackup -GcsBucket 'portaldb-backup' `
 -SourceDbPassword 'KVV0hjhRf&zGXK9j' `
-SourceDbUser 'root' `
-importonly 1
