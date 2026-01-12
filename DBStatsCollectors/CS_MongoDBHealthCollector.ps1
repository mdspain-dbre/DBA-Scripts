## change if you want to debug execution of the script
$DebugPreference = 'SilentlyContinue'
## turn on if you to see the progression through the loop of servers
$InformationPreference = 'Continue'

try {

    ##get-yomomma

    ##Import needed modules
    Import-Module posh-ssh -ErrorAction Stop
    Import-Module dbatools -ErrorAction Stop

    ##Assign Pem file path to a variable  
    $KeyFile = "D:\SSH_Keys\PS_SSHKey.pem"
    ##Assign ubuntu user to variable 
    $User = "ubuntu"
    
    ##Get servers you want to execute against from Servers.MongoDB table via this query
    $MongoProdQuery = "SELECT Top(1) ServerID, IP,Hostname FROM Servers.MongoDB WHERE is_prod = 1"
    ##execute query
    $Servers = Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query $MongoProdQuery -ErrorAction Stop

    ##capture collection time of this script to be inserted into MongoDriveSpace table to aid in reporting
    $collection_time = Get-Date

    ##Loop through Servers
    foreach ($server in $Servers) {

    Write-Information "working on $($Server.Hostname)"

        # Create SSH session
        $SSH_Session = New-SSHSession -ComputerName $($server.IP) -KeyFile $KeyFile -Credential (
            New-Object System.Management.Automation.PSCredential($User,(ConvertTo-SecureString "dummy" -AsPlainText -Force))
        ) -ErrorAction Stop -AcceptKey

$invokeOutput = Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command "mongo --quiet --eval 'rs.status().members'" -ErrorAction Stop

# Remove MongoDB-specific types (ISODate, NumberLong, Timestamp)  Used Claude for this 
$cleanJson = $invokeOutput.Output -replace 'ISODate\("([^"]*)"\)', '"$1"' `
                                  -replace 'NumberLong\((\d+)\)', '$1' `
                                  -replace 'Timestamp\((\d+),\s*(\d+)\)', '{"ts":$1,"i":$2}'

# Parse cleaned JSON
$data = $cleanJson | ConvertFrom-Json

# Select only name, health, and stateStr
$results = $data | Select-Object -Property name, health, stateStr       

$i = 0

        while ($i -lt $results.Count) {

        Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query "Insert into Collector.MongoDBHealthStatus(ServerID,RsStatusName,Health,NodeState,CollectionTime)
                                                                                Values($($Server.ServerID),'$($Results[$i].name)','$($Results[$i].Health)','$($Results[$i].stateStr)','$($collection_time)')"


            $i++

}
        # Close SSH session with no output to console
        Remove-SSHSession -SessionId $SSH_Session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }

    # If everything succeeds
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1  # Causes SQL Agent job to fail
}



