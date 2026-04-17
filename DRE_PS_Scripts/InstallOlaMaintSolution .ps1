
    $params = @{
SqlInstance = 'DRE-Jumpbox'
Database = 'Master'
InstallJobs = $true
BackupLocation = 's3://dre-jumpbox-sql-backups.s3.us-west-2.amazonaws.com/backups/'
AutoScheduleJobs = 'DailyFull'
force = $true
}
Install-DbaMaintenanceSolution @params 