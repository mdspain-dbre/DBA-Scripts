<#
.SYNOPSIS
    Performs MongoDB backup and uploads to AWS S3.

.DESCRIPTION
    This script performs two main operations:
    1. Executes mongodump on a remote Windows server (IP-0A74643F) to create a compressed 
       backup of the MongoDB database
    2. Uploads the backup files to an AWS S3 bucket for offsite storage

    The script is designed to be run as a SQL Server Agent job for automated backup scheduling.

.NOTES
    File Name      : CS_WindowsMongoUploadS3.ps1
    Author         : Michael D'Spain
    Prerequisite   : - AWSPowerShell module installed
                     - AWS credentials configured (via IAM role or Set-AWSCredential)
                     - Network access to \\IP-0A74643F\FullBackup\MongoDB share
                     - Remote PowerShell enabled on target server
                     - mongodump installed on target server

.PARAMETER None
    This script does not accept parameters. Configuration is hardcoded.

.EXAMPLE
    .\CS_WindowsMongoUploadS3.ps1
    
    Runs the backup and upload process.

.OUTPUTS
    Backup files are stored locally at: E:\FullBackup\MongoDB\<timestamp>
    Backup files are uploaded to S3: s3://content-services-windows-mongo-backups/MongoBackups/
#>

#region Module Import
Import-Module AWSPowerShell
#endregion

$ErrorActionPreference = "Stop" # Stop on errors to trigger catch block
$InformationPreference = 'Continue' # Show informational messages

##Get AWS credentials from local files (ensure these files are secure and not accessible to unauthorized users)

$AccesKeyID = Get-Content -path D:\SSH_Keys\AccessKeyID.txt
$SecretAccessKey = Get-Content -path D:\SSH_Keys\AccessKey.txt

$Env:AWS_ACCESS_KEY_ID = $AccesKeyID
$Env:AWS_SECRET_ACCESS_KEY = $SecretAccessKey

Set-AWSCredential -AccessKey $AccesKeyID -SecretKey $SecretAccessKey -StoreAs "mongo-backup"


#region Main Execution
Try {
    #region Preference Variables
    $DebugPreference = "SilentlyContinue"
    $InformationPreference = 'Continue'
    $ErrorActionPreference = "Continue"
    #endregion

Write-Information "Starting MongoDB backup and upload process..." 

    #region Step 1: Execute MongoDB Backup on Remote Server
    # Connect to the MongoDB server and run mongodump to create a compressed backup
    # Backup is stored locally on the remote server with a timestamp folder name
    Invoke-Command -ComputerName "IP-0A74643F" -ScriptBlock {
        
        # Create timestamp for unique backup folder name (format: YYYYMMDD_HHMMSS)
        $date = Get-Date -Format "yyyyMMdd_HHmmss"
        $localPath = "E:\FullBackup\MongoDB\$date"

        # Execute mongodump with gzip compression for space efficiency
        # --host: MongoDB server address and port
        # --gzip: Compress output files
        # --out: Output directory for backup files
        # --quiet: Suppress non-error output
        & mongodump --host=10.116.100.63:27017 --gzip --out=$localPath --quiet

    } # End Invoke-Command ScriptBlock
    #endregion
    
Write-Information "Uploading backup files to AWS S3..."

    #region Step 2: Upload Backup Files to AWS S3
    # Get all backup folders from the network share (excludes root directory)
    # -Recurse -Depth 1: Gets immediate children and their contents
    $BackupPath = Get-ChildItem -Path "\\IP-0A74643F\FullBackup\MongoDB" -Recurse -Depth 1 | 
        Where-Object { $_.FullName -ne "\\IP-0A74643F\FullBackup\MongoDB" }

    # Upload each backup folder to S3
    foreach ($path in $BackupPath) {
        $Filepath = $path.FullName
        
        # Parse the local path to create the S3 key prefix
        # Substring(33) removes "\\IP-0A74643F\FullBackup\MongoDB\" prefix
        # Result: MongoBackups\<timestamp>\<database_name>
        $AWSLoc = 'MongoBackups\' + $path.FullName.Substring(33)

        # Upload folder contents to S3 bucket
        # -BucketName: Target S3 bucket
        # -Folder: Local folder to upload
        # -KeyPrefix: S3 path prefix for uploaded objects
        Write-S3Object -BucketName "content-services-windows-mongo-backups" -Folder $Filepath -KeyPrefix $AWSLoc

    } # End foreach loop
    #endregion

} # End Try block
catch [Exception] {
    # Log error message and exit with non-zero code for SQL Agent job failure detection
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} # End Catch block
#endregion
