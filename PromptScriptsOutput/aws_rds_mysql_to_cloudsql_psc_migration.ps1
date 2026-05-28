#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Script intent
# -----------------------------------------------------------------------------
# This PowerShell script mirrors the staged migration workflow implemented in
# the bash version, with the same safety and operational model:
# - source read-only migration path (mysqldump)
# - explicit cleanup confirmations for destructive steps
# - persisted run-state for resumable stage execution
# - support for safer secret retrieval via SSM Parameter Store
#
# Recommended usage:
# - run one stage at a time
# - inspect run logs between stages
# - keep cleanup as a separate, explicit operator action
# -----------------------------------------------------------------------------

# AWS RDS MySQL -> GCP Cloud SQL MySQL migration orchestrator (PowerShell)
# Stage-based workflow equivalent to the bash version.
# Source operations are read-only; cleanup remains explicit/confirmed.

param(
    [Parameter(Position = 0)]
    [string]$Stage
)

function Get-EnvDefault {
    param(
        [string]$Name,
        [string]$Default
    )
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

# Configuration values are stored in script scope so every function reads the
# same canonical values without needing to pass large parameter sets around.
# Configuration (override via environment variables)
$script:AWS_PROFILE = Get-EnvDefault -Name 'AWS_PROFILE' -Default 'inscape-production-us-1-inscape-aws-ops'
$script:AWS_REGION = Get-EnvDefault -Name 'AWS_REGION' -Default 'us-east-1'
$script:RDS_ENDPOINT = Get-EnvDefault -Name 'RDS_ENDPOINT' -Default 'prod-rds-auxdb-qa-80-20240808.cujpo2r0mujo.us-east-1.rds.amazonaws.com'
$script:RDS_PORT = Get-EnvDefault -Name 'RDS_PORT' -Default '3306'
$script:RDS_USER = Get-EnvDefault -Name 'RDS_USER' -Default 'master'
$script:RDS_PASSWORD = Get-EnvDefault -Name 'RDS_PASSWORD' -Default ''
$script:RDS_PASSWORD_PARAM = Get-EnvDefault -Name 'RDS_PASSWORD_PARAM' -Default ''

$script:GCP_PROJECT_ID = Get-EnvDefault -Name 'GCP_PROJECT_ID' -Default 'vz-inscape-portfolio-dev'
$script:GCP_REGION = Get-EnvDefault -Name 'GCP_REGION' -Default 'us-west1'
$script:GCP_ZONE = Get-EnvDefault -Name 'GCP_ZONE' -Default 'us-west1-a'
$script:CLOUDSQL_INSTANCE = Get-EnvDefault -Name 'CLOUDSQL_INSTANCE' -Default 'auxdb-qa-dre-test2'
$script:CLOUDSQL_DB_VERSION = Get-EnvDefault -Name 'CLOUDSQL_DB_VERSION' -Default 'MYSQL_8_0'
$script:CLOUDSQL_TIER = Get-EnvDefault -Name 'CLOUDSQL_TIER' -Default 'db-custom-2-7680'
$script:CLOUDSQL_DISK_SIZE_GB = Get-EnvDefault -Name 'CLOUDSQL_DISK_SIZE_GB' -Default '300'
$script:CLOUDSQL_ROOT_PASSWORD = Get-EnvDefault -Name 'CLOUDSQL_ROOT_PASSWORD' -Default ''
$script:ALLOWED_PSC_PROJECTS = Get-EnvDefault -Name 'ALLOWED_PSC_PROJECTS' -Default 'vz-inscape-portfolio-dev,vz-inscape-dev'

$script:SOURCE_CLIENT_SG_ID = Get-EnvDefault -Name 'SOURCE_CLIENT_SG_ID' -Default 'sg-750d9c02'

$script:DUMP_VPC_ID = Get-EnvDefault -Name 'DUMP_VPC_ID' -Default ''
$script:DUMP_SUBNET_ID = Get-EnvDefault -Name 'DUMP_SUBNET_ID' -Default ''
$script:DUMP_SG_ID = Get-EnvDefault -Name 'DUMP_SG_ID' -Default ''

$dateCompact = Get-Date -Format 'yyyyMMdd'
$tsCompact = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:S3_BUCKET = Get-EnvDefault -Name 'S3_BUCKET' -Default "auxdb-qa-mysql-dump-$dateCompact"
$script:S3_KEY = Get-EnvDefault -Name 'S3_KEY' -Default "auxdb_full_${tsCompact}.sql.gz"
$script:GCS_BUCKET = Get-EnvDefault -Name 'GCS_BUCKET' -Default "gs://auxdb-qa-mysql-dump-$dateCompact"
$script:GCS_OBJECT = Get-EnvDefault -Name 'GCS_OBJECT' -Default $script:S3_KEY

$script:SCRIPT_DIR = Split-Path -Parent $PSCommandPath
$script:RUN_DIR = Join-Path $script:SCRIPT_DIR ("migration_run_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:STATE_FILE = Join-Path $script:RUN_DIR 'resource_state.log'
$script:LOG_FILE = Join-Path $script:RUN_DIR 'migration.log'
$script:IMPORT_WATCH_SCRIPT = Join-Path $script:RUN_DIR 'watch_import.ps1'
$script:TRANSFER_SCRIPT = Join-Path $script:RUN_DIR 'transfer_s3_to_gcs.sh'

New-Item -ItemType Directory -Path $script:RUN_DIR -Force | Out-Null
New-Item -ItemType File -Path $script:STATE_FILE -Force | Out-Null
New-Item -ItemType File -Path $script:LOG_FILE -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $script:LOG_FILE -Append | Out-Null
}

function Record-State {
    # Append key=value entries to run state for cross-stage continuity.
    # A stage can be rerun later and still discover previously created IDs.
    param(
        [string]$Key,
        [string]$Value
    )
    "{0}={1}" -f $Key, $Value | Out-File -FilePath $script:STATE_FILE -Append -Encoding ascii
}

function Get-StateValue {
    # Return the latest value for a given key from the state file.
    # We intentionally keep this simple text-based state for auditability.
    param([string]$Key)
    if (-not (Test-Path $script:STATE_FILE)) { return '' }
    $line = Select-String -Path $script:STATE_FILE -Pattern ("^{0}=" -f [regex]::Escape($Key)) | Select-Object -Last 1
    if (-not $line) { return '' }
    return ($line.Line -replace ('^{0}=' -f [regex]::Escape($Key)), '')
}

function Require-Cmd {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Require-NonEmpty {
    param(
        [string]$Name,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required variable is empty: $Name"
    }
}

function Require-Secret {
    # Source DB password can be provided directly (RDS_PASSWORD) or resolved
    # on demand from SSM (RDS_PASSWORD_PARAM). At least one is required.
    if ([string]::IsNullOrWhiteSpace($script:RDS_PASSWORD) -and [string]::IsNullOrWhiteSpace($script:RDS_PASSWORD_PARAM)) {
        throw 'Set either RDS_PASSWORD or RDS_PASSWORD_PARAM'
    }
}

function Invoke-Aws {
    # Wrapper around aws CLI to ensure consistent profile/region use and
    # predictable error handling behavior.
    param(
        [string[]]$Args,
        [switch]$AllowFailure
    )
    $output = & aws --profile $script:AWS_PROFILE --region $script:AWS_REGION @Args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "aws command failed: aws $($Args -join ' ')`n$output"
    }
    return ($output -join "`n").Trim()
}

function Invoke-Gcloud {
    # Wrapper around gcloud CLI to ensure consistent project targeting and
    # predictable error handling behavior.
    param(
        [string[]]$Args,
        [switch]$AllowFailure
    )
    $output = & gcloud --project $script:GCP_PROJECT_ID @Args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "gcloud command failed: gcloud --project $script:GCP_PROJECT_ID $($Args -join ' ')`n$output"
    }
    return ($output -join "`n").Trim()
}

function Resolve-RdsPassword {
    # Resolve source password at runtime.
    # Plaintext env var takes precedence; otherwise pull from SSM parameter.
    if (-not [string]::IsNullOrWhiteSpace($script:RDS_PASSWORD)) {
        return $script:RDS_PASSWORD
    }

    return Invoke-Aws -Args @(
        'ssm', 'get-parameter',
        '--name', $script:RDS_PASSWORD_PARAM,
        '--with-decryption',
        '--query', 'Parameter.Value',
        '--output', 'text'
    )
}

function Get-RdsFieldByEndpoint {
    # Query one field from RDS metadata by matching exact endpoint address.
    # Used to enforce same-VPC/same-AZ dump host placement.
    param([string]$Jmes)
    $query = "DBInstances[?Endpoint.Address=='$($script:RDS_ENDPOINT)'].$Jmes | [0]"
    return Invoke-Aws -Args @('rds', 'describe-db-instances', '--query', $query, '--output', 'text')
}

function Wait-ForS3ObjectStable {
    # Wait for S3 object size to stop changing across consecutive checks.
    # This helps avoid transferring a partially uploaded dump file to GCS.
    param(
        [string]$Bucket,
        [string]$Key,
        [int]$Checks = 3,
        [int]$IntervalSeconds = 60
    )

    Write-Log "Waiting for s3://$Bucket/$Key size to stabilize"
    $prev = ''
    $stable = 0

    while ($true) {
        $cur = Invoke-Aws -Args @('s3api', 'head-object', '--bucket', $Bucket, '--key', $Key, '--query', 'ContentLength', '--output', 'text') -AllowFailure
        if ([string]::IsNullOrWhiteSpace($cur)) { $cur = 'MISSING' }

        if ($cur -eq 'MISSING' -or $cur -match 'Not Found|404') {
            $prev = ''
            $stable = 0
        }
        elseif ($prev -eq $cur) {
            $stable++
            if ($stable -ge $Checks) {
                Write-Log "S3 object size stable at $cur bytes"
                return
            }
        }
        else {
            $prev = $cur
            $stable = 0
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Confirm-OrExit {
    # Hard stop helper used for destructive operations.
    param([string]$Prompt)
    $answer = Read-Host "$Prompt [y/N]"
    if ($answer -notin @('y', 'Y')) {
        Write-Log 'User did not confirm. Exiting stage.'
        exit 0
    }
}

function Stage-Preflight {
    # Stage purpose:
    # - verify local tools and auth are available
    # - verify mandatory secret/variable inputs
    # - collect baseline policy/quota diagnostics
    #
    # Side effects:
    # - read-only checks only
    Write-Log 'Running preflight checks'
    Require-Cmd 'aws'
    Require-Cmd 'gcloud'
    Require-Cmd 'mysql'

    Require-Secret
    Require-NonEmpty -Name 'CLOUDSQL_ROOT_PASSWORD' -Value $script:CLOUDSQL_ROOT_PASSWORD

    Write-Log 'Checking AWS caller identity'
    Invoke-Aws -Args @('sts', 'get-caller-identity') | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Checking gcloud auth account'
    (& gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>&1) -join "`n" | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Checking source RDS instance metadata'
    $query = "DBInstances[?Endpoint.Address=='$($script:RDS_ENDPOINT)'].[DBInstanceIdentifier,Engine,EngineVersion,AvailabilityZone,VpcSecurityGroups[*].VpcSecurityGroupId]"
    Invoke-Aws -Args @('rds', 'describe-db-instances', '--query', $query, '--output', 'table') | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Checking Cloud SQL org policy constraints/sql.restrictPublicIp'
    Invoke-Gcloud -Args @('resource-manager', 'org-policies', 'describe', 'constraints/sql.restrictPublicIp', '--project', $script:GCP_PROJECT_ID, '--format=json') -AllowFailure | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Checking AWS EC2 quota snapshot'
    Invoke-Aws -Args @('service-quotas', 'list-service-quotas', '--service-code', 'ec2', '--query', 'Quotas[?contains(QuotaName, `On-Demand`) || contains(QuotaName, `Running`)][QuotaName,Value]', '--output', 'table') -AllowFailure | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Checking GCP compute CPU quotas'
    Invoke-Gcloud -Args @('compute', 'project-info', 'describe', '--project', $script:GCP_PROJECT_ID, '--format=json(quotas)') -AllowFailure | Out-File -FilePath $script:LOG_FILE -Append -Encoding utf8

    Write-Log 'Preflight complete'
}

function Stage-InventorySource {
    # Stage purpose:
    # - inventory source user databases and estimated sizes
    # - persist database list for dump stage
    #
    # Side effects:
    # - writes source_db_sizes.tsv and SOURCE_DATABASE_LIST state
    Write-Log 'Inventorying source user databases and estimated sizes'
    $sourcePwd = Resolve-RdsPassword

    $query = @'
SELECT
  table_schema AS database_name,
  ROUND(SUM(data_length + index_length)/1024/1024,2) AS size_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp')
GROUP BY table_schema
ORDER BY size_mb DESC;
'@

    $oldPwd = $env:MYSQL_PWD
    $env:MYSQL_PWD = $sourcePwd
    try {
        $mysqlOut = & mysql -h $script:RDS_ENDPOINT -P $script:RDS_PORT -u $script:RDS_USER -N -e $query 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "mysql inventory query failed: $($mysqlOut -join "`n")"
        }
    }
    finally {
        $env:MYSQL_PWD = $oldPwd
    }

    $sourceFile = Join-Path $script:RUN_DIR 'source_db_sizes.tsv'
    ($mysqlOut -join "`n") | Out-File -FilePath $sourceFile -Encoding ascii

    $dbList = @()
    foreach ($line in $mysqlOut) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $dbList += (($line -split '\s+')[0])
    }

    $dbJoined = ($dbList -join ' ').Trim()
    Record-State -Key 'SOURCE_DATABASE_LIST' -Value $dbJoined
    Write-Log 'Source DB list recorded'
}

function Stage-CreateTarget {
    # Stage purpose:
    # - create Cloud SQL instance configured for PSC-only connectivity
    # - apply target engine/tier/storage settings
    #
    # Side effects:
    # - creates Cloud SQL target instance
    # - records connection name in state
    Write-Log 'Creating Cloud SQL instance with private PSC configuration'

    Invoke-Gcloud -Args @(
        'sql', 'instances', 'create', $script:CLOUDSQL_INSTANCE,
        "--database-version=$($script:CLOUDSQL_DB_VERSION)",
        "--region=$($script:GCP_REGION)",
        "--tier=$($script:CLOUDSQL_TIER)",
        '--edition=ENTERPRISE',
        '--availability-type=ZONAL',
        '--storage-type=SSD',
        "--storage-size=$($script:CLOUDSQL_DISK_SIZE_GB)",
        '--storage-auto-increase',
        "--root-password=$($script:CLOUDSQL_ROOT_PASSWORD)",
        '--no-assign-ip',
        '--enable-private-service-connect',
        "--allowed-psc-projects=$($script:ALLOWED_PSC_PROJECTS)",
        '--backup-start-time=03:00'
    ) | Out-Null

    $connName = Invoke-Gcloud -Args @('sql', 'instances', 'describe', $script:CLOUDSQL_INSTANCE, '--format=value(connectionName)')
    Record-State -Key 'CLOUDSQL_CONNECTION_NAME' -Value $connName
    Write-Log "Cloud SQL created: $connName"
}

function Stage-StageBuckets {
    # Stage purpose:
    # - create and harden S3 + GCS staging buckets
    # - grant Cloud SQL service account read access for import object
    #
    # Side effects:
    # - bucket creation and IAM binding changes
    Write-Log 'Creating S3 bucket with SSE-S3 + public block'

    $head = Invoke-Aws -Args @('s3api', 'head-bucket', '--bucket', $script:S3_BUCKET) -AllowFailure
    if ($head -match 'Not Found|404|NoSuchBucket|Forbidden' -or [string]::IsNullOrWhiteSpace($head)) {
        if ($script:AWS_REGION -eq 'us-east-1') {
            Invoke-Aws -Args @('s3api', 'create-bucket', '--bucket', $script:S3_BUCKET) | Out-Null
        }
        else {
            Invoke-Aws -Args @('s3api', 'create-bucket', '--bucket', $script:S3_BUCKET, '--create-bucket-configuration', "LocationConstraint=$($script:AWS_REGION)") | Out-Null
        }
    }

    Invoke-Aws -Args @('s3api', 'put-public-access-block', '--bucket', $script:S3_BUCKET, '--public-access-block-configuration', 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true') | Out-Null
    Invoke-Aws -Args @('s3api', 'put-bucket-encryption', '--bucket', $script:S3_BUCKET, '--server-side-encryption-configuration', '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}') | Out-Null
    Record-State -Key 'S3_BUCKET' -Value $script:S3_BUCKET

    Write-Log "Creating GCS bucket with UBLA in $($script:GCP_REGION)"
    $gcsDesc = & gcloud storage buckets describe $script:GCS_BUCKET 2>&1
    if ($LASTEXITCODE -ne 0) {
        & gcloud storage buckets create $script:GCS_BUCKET "--project=$($script:GCP_PROJECT_ID)" "--location=$($script:GCP_REGION)" --uniform-bucket-level-access | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create GCS bucket' }
    }
    Record-State -Key 'GCS_BUCKET' -Value $script:GCS_BUCKET

    Write-Log 'Granting Cloud SQL service account objectViewer on GCS bucket'
    $projectNumber = (& gcloud projects describe $script:GCP_PROJECT_ID '--format=value(projectNumber)' 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Failed to resolve project number: $projectNumber" }
    $projectNumber = $projectNumber.Trim()
    $cloudSqlSa = "service-$projectNumber@gcp-sa-cloud-sql.iam.gserviceaccount.com"

    & gcloud storage buckets add-iam-policy-binding $script:GCS_BUCKET "--member=serviceAccount:$cloudSqlSa" '--role=roles/storage.objectViewer' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'Bucket IAM failed; applying fallback project-level role'
        & gcloud projects add-iam-policy-binding $script:GCP_PROJECT_ID "--member=serviceAccount:$cloudSqlSa" '--role=roles/storage.objectViewer' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply fallback project IAM binding' }
        Record-State -Key 'CLOUDSQL_IAM_BINDING_SCOPE' -Value 'project-fallback'
    }
    else {
        Record-State -Key 'CLOUDSQL_IAM_BINDING_SCOPE' -Value 'bucket'
    }

    Record-State -Key 'CLOUDSQL_SERVICE_ACCOUNT' -Value $cloudSqlSa
}

function Stage-LaunchDumpHost {
    # Stage purpose:
    # - create throwaway EC2 dump host and required IAM role/profile
    # - enforce same VPC/AZ as source RDS
    # - verify/authorize SG path for MySQL 3306 access
    #
    # Side effects:
    # - IAM role/profile and EC2 resources are created
    # - ingress rule may be added on SOURCE_CLIENT_SG_ID
    Write-Log 'Preparing IAM role/profile for dump EC2'

    $suffix = Get-Date -Format 'yyyyMMddHHmmss'
    $roleName = "auxdb-dump-ec2-role-$suffix"
    $profileName = "auxdb-dump-ec2-profile-$suffix"
    $policyName = 'auxdb-dump-s3-write-policy'

    $trustJson = Join-Path $script:RUN_DIR 'ec2-trust.json'
    $policyJson = Join-Path $script:RUN_DIR 'ec2-s3-inline-policy.json'

    $awsAccountId = Invoke-Aws -Args @('sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
    Record-State -Key 'AWS_ACCOUNT_ID' -Value $awsAccountId

    $statements = @(
        @{
            Effect = 'Allow'
            Action = @('s3:PutObject', 's3:AbortMultipartUpload', 's3:ListBucket', 's3:GetBucketLocation')
            Resource = @("arn:aws:s3:::$($script:S3_BUCKET)", "arn:aws:s3:::$($script:S3_BUCKET)/*")
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($script:RDS_PASSWORD_PARAM)) {
        # Least-privilege secret permissions are only added when SSM secret
        # retrieval is enabled.
        $paramPath = $script:RDS_PASSWORD_PARAM.TrimStart('/')
        $parameterArn = "arn:aws:ssm:$($script:AWS_REGION):$awsAccountId`:parameter/$paramPath"

        $statements += @{
            Effect = 'Allow'
            Action = @('ssm:GetParameter')
            Resource = $parameterArn
        }

        $statements += @{
            Effect = 'Allow'
            Action = @('kms:Decrypt')
            Resource = '*'
            Condition = @{
                StringEquals = @{
                    'kms:ViaService' = "ssm.$($script:AWS_REGION).amazonaws.com"
                    'kms:CallerAccount' = $awsAccountId
                }
            }
        }

        Record-State -Key 'RDS_PASSWORD_PARAM' -Value $script:RDS_PASSWORD_PARAM
        Record-State -Key 'RDS_PASSWORD_PARAM_ARN' -Value $parameterArn
    }

    $trust = @{
        Version = '2012-10-17'
        Statement = @(
            @{
                Effect = 'Allow'
                Principal = @{ Service = 'ec2.amazonaws.com' }
                Action = 'sts:AssumeRole'
            }
        )
    }

    $policy = @{
        Version = '2012-10-17'
        Statement = $statements
    }

    ($trust | ConvertTo-Json -Depth 10) | Out-File -FilePath $trustJson -Encoding ascii
    ($policy | ConvertTo-Json -Depth 15) | Out-File -FilePath $policyJson -Encoding ascii

    Invoke-Aws -Args @('iam', 'create-role', '--role-name', $roleName, '--assume-role-policy-document', "file://$trustJson") | Out-Null
    Invoke-Aws -Args @('iam', 'attach-role-policy', '--role-name', $roleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') | Out-Null
    Invoke-Aws -Args @('iam', 'put-role-policy', '--role-name', $roleName, '--policy-name', $policyName, '--policy-document', "file://$policyJson") | Out-Null

    Invoke-Aws -Args @('iam', 'create-instance-profile', '--instance-profile-name', $profileName) | Out-Null
    Invoke-Aws -Args @('iam', 'add-role-to-instance-profile', '--instance-profile-name', $profileName, '--role-name', $roleName) | Out-Null

    Record-State -Key 'DUMP_EC2_ROLE' -Value $roleName
    Record-State -Key 'DUMP_EC2_PROFILE' -Value $profileName
    Record-State -Key 'DUMP_EC2_ROLE_POLICY' -Value $policyName

    $rdsVpcId = Get-RdsFieldByEndpoint -Jmes 'DBSubnetGroup.VpcId'
    $rdsAz = Get-RdsFieldByEndpoint -Jmes 'AvailabilityZone'
    $sgQuery = "DBInstances[?Endpoint.Address=='$($script:RDS_ENDPOINT)'].VpcSecurityGroups[].VpcSecurityGroupId"
    $rdsSgs = Invoke-Aws -Args @('rds', 'describe-db-instances', '--query', $sgQuery, '--output', 'text')

    if ([string]::IsNullOrWhiteSpace($rdsVpcId) -or $rdsVpcId -eq 'None' -or [string]::IsNullOrWhiteSpace($rdsAz) -or $rdsAz -eq 'None') {
        throw "Could not resolve source RDS VPC/AZ from endpoint $($script:RDS_ENDPOINT)"
    }

    Record-State -Key 'SOURCE_RDS_VPC_ID' -Value $rdsVpcId
    Record-State -Key 'SOURCE_RDS_AZ' -Value $rdsAz

    $sgList = ($rdsSgs -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($sgList -notcontains $script:SOURCE_CLIENT_SG_ID) {
        throw "SOURCE_CLIENT_SG_ID=$($script:SOURCE_CLIENT_SG_ID) is not attached to source RDS"
    }

    if (-not [string]::IsNullOrWhiteSpace($script:DUMP_VPC_ID) -and $script:DUMP_VPC_ID -ne $rdsVpcId) {
        throw "DUMP_VPC_ID ($($script:DUMP_VPC_ID)) must match source RDS VPC ($rdsVpcId)"
    }
    $script:DUMP_VPC_ID = $rdsVpcId

    if ([string]::IsNullOrWhiteSpace($script:DUMP_SUBNET_ID)) {
        $script:DUMP_SUBNET_ID = Invoke-Aws -Args @(
            'ec2', 'describe-subnets',
            '--filters',
            "Name=vpc-id,Values=$($script:DUMP_VPC_ID)",
            "Name=availability-zone,Values=$rdsAz",
            'Name=map-public-ip-on-launch,Values=true',
            '--query', 'Subnets[0].SubnetId',
            '--output', 'text'
        )
    }

    if ([string]::IsNullOrWhiteSpace($script:DUMP_SUBNET_ID) -or $script:DUMP_SUBNET_ID -eq 'None') {
        throw "Could not find a public subnet in source RDS VPC/AZ ($($script:DUMP_VPC_ID)/$rdsAz). Set DUMP_SUBNET_ID explicitly."
    }

    $subnetVpc = Invoke-Aws -Args @('ec2', 'describe-subnets', '--subnet-ids', $script:DUMP_SUBNET_ID, '--query', 'Subnets[0].VpcId', '--output', 'text')
    $subnetAz = Invoke-Aws -Args @('ec2', 'describe-subnets', '--subnet-ids', $script:DUMP_SUBNET_ID, '--query', 'Subnets[0].AvailabilityZone', '--output', 'text')
    if ($subnetVpc -ne $rdsVpcId -or $subnetAz -ne $rdsAz) {
        throw "DUMP_SUBNET_ID must be in source RDS VPC/AZ ($rdsVpcId/$rdsAz); got $subnetVpc/$subnetAz"
    }

    if ([string]::IsNullOrWhiteSpace($script:DUMP_SG_ID)) {
        $script:DUMP_SG_ID = Invoke-Aws -Args @(
            'ec2', 'create-security-group',
            '--group-name', "auxdb-dump-host-$suffix",
            '--description', 'Dump host for auxdb migration',
            '--vpc-id', $script:DUMP_VPC_ID,
            '--query', 'GroupId',
            '--output', 'text'
        )
    }

    Invoke-Aws -Args @(
        'ec2', 'authorize-security-group-ingress',
        '--group-id', $script:SOURCE_CLIENT_SG_ID,
        '--ip-permissions', "[{`"IpProtocol`":`"tcp`",`"FromPort`":3306,`"ToPort`":3306,`"UserIdGroupPairs`": [{`"GroupId`":`"$($script:DUMP_SG_ID)`"}]}]"
    ) -AllowFailure | Out-Null

    Write-Log 'Resolving latest Amazon Linux 2023 AMI'
    $al2023Ami = Invoke-Aws -Args @(
        'ssm', 'get-parameter',
        '--name', '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64',
        '--query', 'Parameter.Value',
        '--output', 'text'
    )

    $instanceId = Invoke-Aws -Args @(
        'ec2', 'run-instances',
        '--image-id', $al2023Ami,
        '--instance-type', 't3.medium',
        '--iam-instance-profile', "Name=$profileName",
        '--subnet-id', $script:DUMP_SUBNET_ID,
        '--security-group-ids', $script:DUMP_SG_ID,
        '--block-device-mappings', '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]',
        '--tag-specifications', 'ResourceType=instance,Tags=[{Key=Name,Value=auxdb-migration-dump-host}]',
        '--query', 'Instances[0].InstanceId',
        '--output', 'text'
    )

    Record-State -Key 'DUMP_EC2_INSTANCE_ID' -Value $instanceId
    Record-State -Key 'DUMP_EC2_SG_ID' -Value $script:DUMP_SG_ID
    Record-State -Key 'DUMP_EC2_SUBNET_ID' -Value $script:DUMP_SUBNET_ID
    Record-State -Key 'DUMP_VPC_ID' -Value $script:DUMP_VPC_ID

    Write-Log "Waiting for EC2 $instanceId to be running and managed by SSM"
    Invoke-Aws -Args @('ec2', 'wait', 'instance-running', '--instance-ids', $instanceId) | Out-Null

    for ($i = 0; $i -lt 30; $i++) {
        $ssmId = Invoke-Aws -Args @('ssm', 'describe-instance-information', '--filters', "Key=InstanceIds,Values=$instanceId", '--query', 'InstanceInformationList[0].InstanceId', '--output', 'text') -AllowFailure
        if ($ssmId -eq $instanceId) { break }
        Start-Sleep -Seconds 10
    }

    Write-Log "Dump host ready: $instanceId"
}

function Stage-StartDump {
    # Stage purpose:
    # - submit remote dump pipeline via SSM Run Command
    # - run dump asynchronously on EC2 into S3
    #
    # Security note:
    # - SSM parameter mode avoids embedding plaintext source password where
    #   possible.
    $instanceId = Get-StateValue -Key 'DUMP_EC2_INSTANCE_ID'
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        throw 'No dump host in state file. Run launch-dump-host first.'
    }

    $dbList = Get-StateValue -Key 'SOURCE_DATABASE_LIST'
    if ([string]::IsNullOrWhiteSpace($dbList)) {
        Write-Log 'SOURCE_DATABASE_LIST missing; collecting inventory now.'
        Stage-InventorySource
        $dbList = Get-StateValue -Key 'SOURCE_DATABASE_LIST'
    }

    Write-Log 'Sending dump command via SSM using --cli-input-json'
    $ssmPayload = Join-Path $script:RUN_DIR 'ssm-start-dump.json'

    if (-not [string]::IsNullOrWhiteSpace($script:RDS_PASSWORD_PARAM)) {
        $mysqlPwdCmd = "export MYSQL_PWD=`$(aws ssm get-parameter --name '$($script:RDS_PASSWORD_PARAM)' --with-decryption --query Parameter.Value --output text)"
    }
    else {
        Write-Log 'WARNING: Using RDS_PASSWORD plaintext in transient SSM payload. Prefer RDS_PASSWORD_PARAM.'
        $mysqlPwdCmd = "export MYSQL_PWD='$($script:RDS_PASSWORD)'"
    }

    $commands = @(
        'set -euo pipefail',
        'sudo dnf install -y mysql pigz >/tmp/dump_pkg_install.log 2>&1',
        "cat > /tmp/run_dump.sh <<'EOS'",
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        $mysqlPwdCmd,
        "nohup bash -c `"mysqldump -h $($script:RDS_ENDPOINT) -P $($script:RDS_PORT) -u $($script:RDS_USER) --single-transaction --routines --triggers --events --databases $dbList | sed -E 's/DEFINER=[^*]*\*/\*/g; /SET @@GLOBAL.GTID_PURGED/d; /SET @@SESSION.SQL_LOG_BIN/d' | pigz -1 | aws s3 cp - s3://$($script:S3_BUCKET)/$($script:S3_KEY)`" > /var/log/auxdb_dump.log 2>&1 & disown",
        'echo STARTED > /tmp/dump_started.flag',
        'EOS',
        'chmod +x /tmp/run_dump.sh',
        '/tmp/run_dump.sh',
        "aws s3 ls s3://$($script:S3_BUCKET)/ --human-readable --summarize || true"
    )

    $payload = @{
        DocumentName = 'AWS-RunShellScript'
        Comment = 'Start non-blocking mysqldump to S3'
        InstanceIds = @($instanceId)
        Parameters = @{ commands = $commands }
    }

    ($payload | ConvertTo-Json -Depth 10) | Out-File -FilePath $ssmPayload -Encoding ascii

    $ssmCmdId = Invoke-Aws -Args @('ssm', 'send-command', '--cli-input-json', "file://$ssmPayload", '--query', 'Command.CommandId', '--output', 'text')
    Remove-Item -Path $ssmPayload -Force -ErrorAction SilentlyContinue

    Record-State -Key 'DUMP_SSM_COMMAND_ID' -Value $ssmCmdId
    Write-Log "Dump command submitted. CommandId=$ssmCmdId"
    Write-Log "Monitor S3 object growth at s3://$($script:S3_BUCKET)/$($script:S3_KEY)"
}

function Stage-TransferToGcs {
    # Stage purpose:
    # - stream completed dump object from S3 to GCS
    # - launch transfer helper in background for shell/session resilience
    Write-Log 'Writing transfer helper script and launching in background'
    Wait-ForS3ObjectStable -Bucket $script:S3_BUCKET -Key $script:S3_KEY -Checks 3 -IntervalSeconds 60

    $transferBody = @"
#!/usr/bin/env bash
set -euo pipefail
{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting S3 -> GCS streaming transfer"
  aws --profile "$($script:AWS_PROFILE)" --region "$($script:AWS_REGION)" s3 cp "s3://$($script:S3_BUCKET)/$($script:S3_KEY)" - | gcloud storage cp - "$($script:GCS_BUCKET)/$($script:GCS_OBJECT)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Transfer complete"
} >> "$($script:RUN_DIR)/transfer_s3_to_gcs.log" 2>&1
"@

    $transferBody | Out-File -FilePath $script:TRANSFER_SCRIPT -Encoding ascii
    & chmod +x $script:TRANSFER_SCRIPT | Out-Null

    Start-Process -FilePath '/bin/bash' -ArgumentList @($script:TRANSFER_SCRIPT) -WindowStyle Hidden | Out-Null

    Record-State -Key 'GCS_DUMP_URI' -Value "$($script:GCS_BUCKET)/$($script:GCS_OBJECT)"
    Write-Log "Transfer started in background. Log: $($script:RUN_DIR)/transfer_s3_to_gcs.log"
}

function Stage-PatchFlag {
    # Stage purpose:
    # - patch Cloud SQL with required pre-import DB flag
    #
    # Why required:
    # - routine/trigger definitions may fail import without this setting.
    Write-Log 'Patching Cloud SQL flag log_bin_trust_function_creators=on'
    $opId = Invoke-Gcloud -Args @('sql', 'instances', 'patch', $script:CLOUDSQL_INSTANCE, '--database-flags=log_bin_trust_function_creators=on', '--quiet', '--format=value(name)')
    Record-State -Key 'PATCH_OPERATION_ID' -Value $opId
    Write-Log "Waiting for patch operation $opId"
    Invoke-Gcloud -Args @('sql', 'operations', 'wait', $opId, '--timeout=3600') | Out-Null
    Write-Log 'Flag patch completed'
}

function Stage-StartImport {
    # Stage purpose:
    # - start Cloud SQL import asynchronously
    # - spawn background watcher to log operation status every 5 minutes
    $gcsUri = Get-StateValue -Key 'GCS_DUMP_URI'
    if ([string]::IsNullOrWhiteSpace($gcsUri)) {
        $gcsUri = "$($script:GCS_BUCKET)/$($script:GCS_OBJECT)"
    }

    Write-Log "Starting Cloud SQL import (async): $gcsUri"
    $opId = Invoke-Gcloud -Args @('sql', 'import', 'sql', $script:CLOUDSQL_INSTANCE, $gcsUri, '--async', '--format=value(name)')
    Record-State -Key 'IMPORT_OPERATION_ID' -Value $opId

    $watchBody = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Continue'
`$opId = '$opId'
while (`$true) {
  `$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  `$status = (& gcloud --project '$($script:GCP_PROJECT_ID)' sql operations describe `$opId --format='value(status)' 2>`$null)
  if (`$LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((`$status -join "`n"))) { `$status = 'UNKNOWN' }
  "`${ts} import_op=`${opId} status=`$((`$status -join "`n").Trim())" | Out-File -FilePath '$($script:RUN_DIR)/import_watch.log' -Append -Encoding utf8
  if ((`$status -join "`n").Trim() -eq 'DONE') {
    (& gcloud --project '$($script:GCP_PROJECT_ID)' sql operations describe `$opId --format=json 2>&1) -join "`n" | Out-File -FilePath '$($script:RUN_DIR)/import_watch.log' -Append -Encoding utf8
    break
  }
  Start-Sleep -Seconds 300
}
"@

    $watchBody | Out-File -FilePath $script:IMPORT_WATCH_SCRIPT -Encoding utf8
    Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $script:IMPORT_WATCH_SCRIPT) -WindowStyle Hidden | Out-Null

    Write-Log 'Import started. Background poller running at 5-minute intervals.'
    Write-Log "Watch logs: $($script:RUN_DIR)/import_watch.log"
}

function Stage-CreateMasterUser {
    # Stage purpose:
    # - create post-import master@% user if absent
    # - keep stage idempotent by skipping when user already exists
    #
    # Additional output:
    # - writes SQL note explaining Cloud SQL privilege constraints.
    Write-Log 'Creating post-import user master@%'
    $sourcePwd = Resolve-RdsPassword

    $usersCsv = Invoke-Gcloud -Args @('sql', 'users', 'list', "--instance=$($script:CLOUDSQL_INSTANCE)", '--format=csv[no-heading](name,host)')
    if ($usersCsv -split "`n" | Where-Object { $_.Trim() -eq 'master,%' }) {
        Write-Log 'User master@% already exists; skipping create.'
        return
    }

    Invoke-Gcloud -Args @('sql', 'users', 'create', 'master', "--instance=$($script:CLOUDSQL_INSTANCE)", "--password=$sourcePwd", "--host=%") | Out-Null

    $privSql = @'
-- Cloud SQL does not permit SUPER privilege.
-- Grant broad legal privileges within Cloud SQL constraints.
GRANT ALL PRIVILEGES ON *.* TO ''master''@''%'' WITH GRANT OPTION;
FLUSH PRIVILEGES;
'@

    $privPath = Join-Path $script:RUN_DIR 'post_import_privileges.sql'
    $privSql | Out-File -FilePath $privPath -Encoding ascii

    Write-Log "Created user. Privilege SQL saved to $privPath"
}

function Stage-Verify {
    # Stage purpose:
    # - generate operator checklist for post-import verification
    # - include proxy usage and source/target count comparisons
    $connName = Invoke-Gcloud -Args @('sql', 'instances', 'describe', $script:CLOUDSQL_INSTANCE, '--format=value(connectionName)')
    Record-State -Key 'CLOUDSQL_CONNECTION_NAME' -Value $connName

    $notes = @"
Verification checklist:
1) Start Cloud SQL Proxy with PSC:
   cloud-sql-proxy --psc $connName

2) Compare DB counts:
   Source:
   MYSQL_PWD='***' mysql -h $($script:RDS_ENDPOINT) -P $($script:RDS_PORT) -u $($script:RDS_USER) -N -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp');"

   Target (through proxy localhost:3306):
   MYSQL_PWD='***' mysql -h 127.0.0.1 -P 3306 -u root -N -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp');"

3) Compare table counts and sample row counts for largest tables.
"@

    $verifyPath = Join-Path $script:RUN_DIR 'verify_notes.txt'
    $notes | Out-File -FilePath $verifyPath -Encoding utf8
    Write-Log "Verification checklist written to $verifyPath"
}

function Stage-Cleanup {
    # Stage purpose:
    # - remove temporary migration resources after verification
    #
    # Destructive actions:
    # - terminates EC2 dump host
    # - deletes IAM role/profile artifacts
    # - deletes S3/GCS dump objects
    #
    # Guardrails:
    # - two explicit operator confirmations are required
    Write-Log 'Cleanup is destructive and intentionally requires explicit confirmation.'
    Write-Log 'This can terminate EC2, detach/delete IAM role+instance profile, and delete S3/GCS dump objects.'
    Confirm-OrExit -Prompt 'Proceed with cleanup now?'

    $instanceId = Get-StateValue -Key 'DUMP_EC2_INSTANCE_ID'
    $roleName = Get-StateValue -Key 'DUMP_EC2_ROLE'
    $profileName = Get-StateValue -Key 'DUMP_EC2_PROFILE'

    if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
        Invoke-Aws -Args @('ec2', 'terminate-instances', '--instance-ids', $instanceId) -AllowFailure | Out-Null
        Write-Log "Terminate requested for $instanceId"
    }

    if (-not [string]::IsNullOrWhiteSpace($profileName) -and -not [string]::IsNullOrWhiteSpace($roleName)) {
        Invoke-Aws -Args @('iam', 'remove-role-from-instance-profile', '--instance-profile-name', $profileName, '--role-name', $roleName) -AllowFailure | Out-Null
        Invoke-Aws -Args @('iam', 'delete-instance-profile', '--instance-profile-name', $profileName) -AllowFailure | Out-Null
        Invoke-Aws -Args @('iam', 'delete-role-policy', '--role-name', $roleName, '--policy-name', 'auxdb-dump-s3-write-policy') -AllowFailure | Out-Null
        Invoke-Aws -Args @('iam', 'detach-role-policy', '--role-name', $roleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') -AllowFailure | Out-Null
        Invoke-Aws -Args @('iam', 'delete-role', '--role-name', $roleName) -AllowFailure | Out-Null
        Write-Log 'IAM role/profile cleanup attempted'
    }

    Confirm-OrExit -Prompt 'Delete dump objects from S3 and GCS?'
    Invoke-Aws -Args @('s3', 'rm', "s3://$($script:S3_BUCKET)/$($script:S3_KEY)") -AllowFailure | Out-Null
    (& gcloud storage rm "$($script:GCS_BUCKET)/$($script:GCS_OBJECT)" 2>&1) | Out-Null
    Write-Log 'Dump object cleanup attempted'
}

function Stage-RunAll {
    # Convenience pipeline through async import start.
    # Cleanup and final verification remain separate operator-driven steps.
    Stage-Preflight
    Stage-InventorySource
    Stage-CreateTarget
    Stage-StageBuckets
    Stage-LaunchDumpHost
    Stage-StartDump
    Stage-TransferToGcs
    Stage-PatchFlag
    Stage-StartImport
    Write-Log 'run-all complete. Import runs asynchronously; monitor before create-master-user/verify.'
}

function Show-Usage {
    # Keep stage names stable for operator runbooks and automation wrappers.
@'
Usage:
  ./aws_rds_mysql_to_cloudsql_psc_migration.ps1 <stage>

Stages:
  preflight
  inventory-source
  create-target
  stage-buckets
  launch-dump-host
  start-dump
  transfer-to-gcs
  patch-flag
  start-import
  create-master-user
  verify
  cleanup
  run-all
'@ | Write-Host
}

switch ($Stage) {
    'preflight' { Stage-Preflight }
    'inventory-source' { Stage-InventorySource }
    'create-target' { Stage-CreateTarget }
    'stage-buckets' { Stage-StageBuckets }
    'launch-dump-host' { Stage-LaunchDumpHost }
    'start-dump' { Stage-StartDump }
    'transfer-to-gcs' { Stage-TransferToGcs }
    'patch-flag' { Stage-PatchFlag }
    'start-import' { Stage-StartImport }
    'create-master-user' { Stage-CreateMasterUser }
    'verify' { Stage-Verify }
    'cleanup' { Stage-Cleanup }
    'run-all' { Stage-RunAll }
    default {
        Show-Usage
        exit 1
    }
}
