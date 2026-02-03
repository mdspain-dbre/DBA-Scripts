Import-Module dbatools 

####### path to the .sql files #######
$files = gci "D:\DRE_PS_Scripts\ContentServicesIndexMaintJobs"

####### ProdSQL1 RDS Instance Name #######
$ProdSQL1 = 'mongo-mssql-1-production.c6ehn5aqgtrp.us-west-2.rds.amazonaws.com'

#######  Create Credential to connect with SQL Auth  #######
$username = "mssql1"
$password = "<retrieve password from AWS Console>" | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $password)


#######  Loop through each file and execute on ProdSQL1  #######

foreach($file in $files.fullname)
    {
    
    Invoke-DbaQuery -SqlInstance $ProdSQL1 -Database MSDB -File $file -SqlCredential $credential
    
    } 