<#
.SYNOPSIS
    Performs MongoDB backup via SSH and streams directly to AWS S3.

.DESCRIPTION
    This script connects to a remote Linux MongoDB server via SSH using the Posh-SSH module,
    executes mongodump with --archive and --gzip flags, and streams the backup directly to S3
    without requiring local disk space on either machine.

.NOTES
    File Name      : CS_MongoBackupToS3_SSH.ps1
    Author         : Michael D'Spain
    Prerequisite   : - Posh-SSH module installed (Install-Module -Name Posh-SSH)
                     - SSH key file accessible
                     - mongodump installed on remote server
                     - AWS CLI installed and configured on remote server (via IAM instance role)
                     - S3 bucket: prod-sql-1-backups

.PARAMETER MongoHost
    The IP address or hostname of the MongoDB server. Default: 10.121.162.210

.PARAMETER KeyFile
    Path to the SSH private key file. Default: D:\SSH_Keys\mongodb-hosts-pipeline-v1.pem

.PARAMETER S3Bucket
    The S3 bucket name for backup storage. Default: prod-sql-1-backups

.PARAMETER S3Prefix
    The S3 key prefix for backups. Default: mongobackups

.PARAMETER Databases
    Array of database names to back up. If empty, backs up all databases.

.EXAMPLE
    .\CS_MongoBackupToS3_SSH.ps1
    Backs up all databases to S3.

.EXAMPLE
    .\CS_MongoBackupToS3_SSH.ps1 -Databases @("ExtruderStateTest")
    Backs up only the ExtruderStateTest database.
#>

param(
    [string]$MongoHost = "10.121.162.210",
    [string]$KeyFile = "D:\SSH_Keys\PS_SSHKey.pem",
    [string]$SSHUser = "ubuntu",
    [string]$S3Bucket = "prod-sql-1-backups",
    [string]$S3Prefix = "mongobackups",
    [string[]]$Databases = @()
)

#region Module Import
Import-Module Posh-SSH
#endregion

$ErrorActionPreference = "Stop"
$InformationPreference = 'Continue'

#region Main Execution
Try {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Write-Information "Connecting to MongoDB server $MongoHost via SSH..."

    # Create SSH session using key file (no passphrase)
    $SSHSession = New-SSHSession -ComputerName $MongoHost `
        -KeyFile $KeyFile `
        -Credential (New-Object System.Management.Automation.PSCredential($SSHUser, (ConvertTo-SecureString "dummy" -AsPlainText -Force))) `
        -AcceptKey

    if (-not $SSHSession.Connected) {
        throw "Failed to establish SSH connection to $MongoHost"
    } ## if SSHSession not connected

    Write-Information "SSH connection established (SessionId: $($SSHSession.SessionId))"

    # If no databases specified, get list of all databases
    if ($Databases.Count -eq 0) {
        Write-Information "No databases specified, discovering all databases..."
        $dbListResult = Invoke-SSHCommand -SessionId $SSHSession.SessionId `
            -Command "mongo --quiet --eval 'db.adminCommand({listDatabases:1}).databases.forEach(function(d){print(d.name)})'" `
            -TimeOut 60

        if ($dbListResult.ExitStatus -ne 0) {
            throw "Failed to list databases: $($dbListResult.Error)"
        } ## if dbListResult exit status check

        # Filter out system databases
        $Databases = $dbListResult.Output | Where-Object { $_ -notin @("admin", "local", "config") -and $_ -ne "" }
        Write-Information "Found databases: $($Databases -join ', ')"
    } ## if no databases specified

    # Back up each database
    foreach ($db in $Databases) {
        $s3Key = "s3://$S3Bucket/$S3Prefix/$db/${timestamp}/${db}_${timestamp}.archive.gz"
        Write-Information "Backing up database '$db' to $s3Key ..."

        $backupCommand = "mongodump --db=$db --archive --gzip | aws s3 cp - $s3Key"

        $result = Invoke-SSHCommand -SessionId $SSHSession.SessionId `
            -Command $backupCommand `
            -TimeOut 3600

        if ($result.ExitStatus -ne 0) {
            Write-Warning "Backup of '$db' failed: $($result.Error)"
            Write-Warning "Output: $($result.Output -join "`n")"
        } ## if backup failed
        else {
            Write-Information "Backup of '$db' completed successfully."
            if ($result.Output) {
                Write-Information ($result.Output -join "`n")
            } ## if result output
        } ## else backup succeeded
    } ## foreach database

    Write-Information "All backups completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

} ## try block
catch [Exception] {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} ## catch block
finally {
    # Clean up SSH session
    if ($SSHSession) {
        Remove-SSHSession -SSHSession (Get-SSHSession) -ErrorAction SilentlyContinue | Out-Null
        Write-Information "SSH session closed."
    } ## if SSHSession cleanup
} ## finally block
#endregion
