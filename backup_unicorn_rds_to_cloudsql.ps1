#!/usr/bin/env pwsh
param(
    [string]$AwsProfile = $env:AWS_PROFILE ?? 'inscape-production-us-1-inscape-aws-ops',
    [string]$AwsRegion = $env:AWS_REGION ?? 'us-east-1',
    [string]$SourceRdsInstance = $env:SOURCE_RDS_INSTANCE ?? 'prod-rds-unicorn-dev-pg18',
    [string]$SourceDb = $env:SOURCE_DB ?? 'unicorn',
    [string]$SourceDbUser = $env:SOURCE_DB_USER ?? 'root',
    [string]$SourceDbPassword = $env:SOURCE_DB_PASSWORD ?? '',
    [string]$GcpProjectId = $env:GCP_PROJECT_ID ?? 'vz-inscape-portfolio-dev',
    [string]$TargetCloudSqlInstance = $env:TARGET_CLOUDSQL_INSTANCE ?? 'admin-portal-db',
    [string]$TargetDb = $env:TARGET_DB ?? 'unicorn',
    [string]$GcsBucket = $env:GCS_BUCKET ?? 'pointsdb-backup',
    [string]$GcsPrefix = $env:GCS_PREFIX ?? 'unicorn-postgres',
    [string]$ImportAsync = $env:IMPORT_ASYNC ?? 'false',
    [string]$PgDumpBin = $env:PG_DUMP_BIN ?? '/opt/homebrew/opt/postgresql@18/bin/pg_dump'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-RdsEndpoint {
    param(
        [string]$Profile,
        [string]$Region,
        [string]$InstanceId
    )

    $output = & aws --profile $Profile --region $Region rds describe-db-instances `
        --db-instance-identifier $InstanceId `
        --query 'DBInstances[0].Endpoint.[Address,Port]' --output text

    $parts = ($output -split '\s+') | Where-Object { $_ }
    if ($parts.Count -lt 2) {
        throw "Unexpected RDS endpoint output: $output"
    }

    [pscustomobject]@{
        Host = $parts[0]
        Port = $parts[1]
    }
}

Write-Host 'Resolving source RDS endpoint'
$endpoint = Get-RdsEndpoint -Profile $AwsProfile -Region $AwsRegion -InstanceId $SourceRdsInstance
Write-Host "Source RDS: $($endpoint.Host):$($endpoint.Port)"

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$gcsUri = "gs://$($GcsBucket.TrimEnd('/'))/$GcsPrefix/${SourceDb}_$timestamp.sql.gz"

Write-Host "Streaming pg_dump | gzip | gcloud storage cp -> $gcsUri"

$oldPassword = $env:PGPASSWORD
$env:PGPASSWORD = $SourceDbPassword
try {
    & $PgDumpBin `
        --host=$endpoint.Host `
        --port=$endpoint.Port `
        --username=$SourceDbUser `
        --dbname=$SourceDb `
        --format=plain `
        --encoding=UTF8 `
        --no-owner `
        --no-privileges `
        --quote-all-identifiers |
    gzip -c |
    gcloud --project $GcpProjectId storage cp - $gcsUri
}
finally {
    $env:PGPASSWORD = $oldPassword
}

Write-Host 'Verifying uploaded object'
& gcloud --project $GcpProjectId storage ls -l $gcsUri

Write-Host 'Starting Cloud SQL import'
if ($ImportAsync -eq 'true') {
    $operationId = & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
        --database=$TargetDb --async --format='value(name)'
    Write-Host "Import started asynchronously. Operation: $operationId"
    Write-Host "Track with: gcloud --project $GcpProjectId sql operations describe $operationId"
}
else {
    & gcloud --project $GcpProjectId sql import sql $TargetCloudSqlInstance $gcsUri `
        --database=$TargetDb --quiet
    Write-Host 'Import completed successfully'
}

Write-Host 'Done'
Write-Host "GCS object: $gcsUri"