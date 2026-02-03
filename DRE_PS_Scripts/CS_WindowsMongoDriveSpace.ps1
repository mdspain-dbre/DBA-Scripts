
# Fail on any error
$ErrorActionPreference = 'Stop'
## change if you want to debug execution of the script
$DebugPreference = 'SilentlyContinue'
## turn on if you to see the progression through the loop of servers
$InformationPreference = 'Continue'

try {



    ##Import needed modules
    Import-Module dbatools -ErrorAction Stop -Scope Local

    $Repo = "DRE-Jumpbox"

    
    ##Get servers you want to execute against from Servers.MongoDB table via this query
    $WindowsMongoProdQuery = "SELECT ServerID, IP,Hostname FROM Servers.MongoDB WHERE is_prod = 1 and is_windows = 1"
    ##execute query

    $WindowsServers = Invoke-DbaQuery -SqlInstance $Repo -Database DBStats -Query $WindowsMongoProdQuery -ErrorAction Stop

    ##capture collection time of this script to be inserted into MongoDriveSpace table to aid in reporting
    $collection_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    ##Loop through Servers
    foreach ($wserver in $WindowsServers) {

   
     $DriveSpace = Get-DbaDiskSpace -ComputerName $($wserver.hostname) -EnableException  | Select @{name='ServerID';expression={$($wserver.ServerID)}}, Name, Capacity, Free, PercentFree,@{name='CollectionTime';expression={$($collection_time)}}

     Write-DbaDbTableData -SqlInstance $Repo -InputObject $DriveSpace -Database DBStats -Table WindowsMongoDBDriveSpace -Schema Collector  -EnableException

    }

    # If everything succeeds
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
      exit 1  # Causes SQL Agent job to fail
}



