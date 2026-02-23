Import-Module AWSPowerShell


Invoke-Command -computername "IP-0A74643F" -ScriptBlock {

Try{

$DebugPreference = "SilentlyContinue"
$InformationPreference = 'Continue'
$ErrorActionPreference = "Continue"  # Fail fast on errors

$date = Get-Date -Format "yyyyMMdd_HHmmss"
$localPath = "E:\FullBackup\MongoDB\$date"
$bucket = "your-bucket"
$s3Path = "mongodb-backups/$date"

# Run mongodump
& mongodump  --host=10.116.100.63:27017 --gzip --out=$localPath --quiet

# Optional: delete local backup
##Remove-Item -Path $localPath -Recurse -Force
}
catch [Exception] {
    # Log error and exit with code 1 to signal failure to SQL Agent
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  ##  exit 1
}

}##ScriptBlock 
      




##Get files to upload 
$BackupPath = get-childitem  -path "\\IP-0A74643F\FullBackup\MongoDB" -Recurse -depth 1 | Where-Object { $_.FullName -ne "\\IP-0A74643F\FullBackup\MongoDB" } 

foreach($path in $BackupPath)
    {
    ##write-host $path.FullName


    $Filepath = $($path.fullname)
    $AWSLoc = 'MongoBackups\'+$path.FullName.Substring(33)
    $AWSLoc 
    
    Write-S3Object -BucketName "content-services-windows-mongo-backups" -Folder $Filepath -KeyPrefix $AWSLoc

    }


