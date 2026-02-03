
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
    $MongoProdQuery = "SELECT ServerID, IP,Hostname FROM Servers.MongoDB WHERE is_prod = 1 and is_linux = 1  and is_arbitor = 0"
    ##execute query
    $LinuxServers = Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query $MongoProdQuery -ErrorAction Stop

    ##Loop through Servers
    foreach ($lserver in $LinuxServers) {

    Write-Information "working on $($lserver.Hostname)"

        # Create SSH session
        $SSH_Session = New-SSHSession -ComputerName $($lserver.IP) -KeyFile $KeyFile -Credential (
            New-Object System.Management.Automation.PSCredential($User,(ConvertTo-SecureString "dummy" -AsPlainText -Force))
        ) -ErrorAction Stop -AcceptKey

       ## $GrepLogCommand = 'ls /mnt/data/log/ | grep "mongod.log."'
        ##$invokeOutput = Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command $GrepLogCommand -ErrorAction Stop

        $RotateLogCommand = "mongo --quiet --eval 'db.adminCommand( { logRotate: 1 } )'"
        $RemoveLogFilesCommand = 'sudo rm /mnt/data/log/mongod.log.*'
       
      
        ##Execute Log rotation command
        Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command $RotateLogCommand -ErrorAction Stop
        ##Execute Remove old log files command
        Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command $RemoveLogFilesCommand -ErrorAction Stop
        ##Clean up SSH session 
        Remove-SSHSession -SessionId $SSH_Session.SessionId -ErrorAction SilentlyContinue | Out-Null

    }  ##foreach block
    # If everything succeeds
    exit 0
} ## try block 
catch   {
    
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1  # Causes SQL Agent job to fail
    
        } ##catch block 
