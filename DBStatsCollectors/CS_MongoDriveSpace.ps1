
# Fail on any error
$ErrorActionPreference = 'Stop'
## change if you want to debug execution of the script
$DebugPreference = 'SilentlyContinue'
## turn on if you to see the progression through the loop of servers
$InformationPreference = 'Continue'

try {



    ##Import needed modules
    Import-Module posh-ssh -ErrorAction Stop -Scope Local
    Import-Module dbatools -ErrorAction Stop -Scope Local

    $Repo = "DRE-Jumpbox"

    ##Assign Pem file path to a variable  
    $KeyFile = "D:\SSH_Keys\PS_SSHKey.pem"
    ##Assign ubuntu user to variable 
    $User = "ubuntu"
    
    ##Get servers you want to execute against from Servers.MongoDB table via this query
    $MongoProdQuery = "SELECT ServerID, IP,Hostname FROM Servers.MongoDB WHERE is_prod = 1 and is_linux = 1"
    ##execute query
    $LinuxServers = Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query $MongoProdQuery -ErrorAction Stop

    ##capture collection time of this script to be inserted into MongoDriveSpace table to aid in reporting
    $collection_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    ##Loop through Servers
    foreach ($lserver in $LinuxServers) {

    Write-Information "working on $($lServer.Hostname)"

        # Create SSH session
        $SSH_Session = New-SSHSession -ComputerName $($lserver.IP) -KeyFile $KeyFile -Credential (
            New-Object System.Management.Automation.PSCredential($User,(ConvertTo-SecureString "dummy" -AsPlainText -Force))
        ) -ErrorAction Stop -AcceptKey

        # Run df -h command
        $invokeOutput = Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command "df -h" -ErrorAction Stop

        ##parge the array returned from df -h
        $separator = " "
        $option = [System.StringSplitOptions]::RemoveEmptyEntries
        $i = 1

        while ($i -lt $invokeOutput.Output.Count) {
            $splitarray = $invokeOutput.Output[$i].Split($separator,$option)

            $InsertQuery = " INSERT INTO Collector.MongoDriveSpace
                (ServerID, filesystem, size, Used, Available, Used_Percentage, Mount, collectionTime)
                VALUES ($($lServer.ServerID), '$($splitarray[0])', '$($splitarray[1])', '$($splitarray[2])' , '$($splitarray[3])', '$($splitarray[4])', '$($splitarray[5])', '$($collection_time)' )"

            ##insert the parsed array into Collector.MongoDriveSpace
            Invoke-DbaQuery -SqlInstance $Repo -Database DBStats -Query $InsertQuery

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
