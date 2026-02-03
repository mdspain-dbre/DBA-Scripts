

Import-Module posh-ssh

$KeyFile = "D:\SSH_Keys\PS_SSHKey.pem"
$User = "ubuntu"   # or your Linux username

$MongoProdQuery = "select ServerID,IP from Servers.MongoDB where is_prod =1"

$Servers = Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query $MongoProdQuery

## populate collection time variable
$collection_time = get-date

foreach($server in $Servers)
    {

# Create SSH session using the key file
$SSH_Session = New-SSHSession -ComputerName $($server.IP) -KeyFile $KeyFile -Credential (New-Object System.Management.Automation.PSCredential($User,(ConvertTo-SecureString "dummy" -AsPlainText -Force)))


## command to execute in SSH session
$invokeOutput = Invoke-SSHCommand -SessionId $($SSH_Session.SessionId) -Command "df -h" -erroraction "silentlycontinue"

## split variables.   df -h returns an array and split function breaks up that array
$separator = " "
$option = [System.StringSplitOptions]::RemoveEmptyEntries

## set counter.  don't set to zero as that is the header of df -h
$i = 1

##loop through the array based on count
while($i -lt $invokeOutput.output.count){

## break up the array splitting on the empty string or whitespace

   $splitarray = $invokeOutput.Output[$i].Split($separator,$option)

<#
$splitarray[0]
$splitarray[1]
$splitarray[2]
$splitarray[3]
$splitarray[4]
$splitarray[5]
#>

Invoke-DbaQuery -SQLInstance DRE-Jumpbox -Database DBStats -query "Insert into Collector.MongoDriveSpace  (ServerID, filesystem, size, Used, Available, Used_Percentage, Mount,collectionTime) values($($Server.ServerID),'$($splitarray[0])','$($splitarray[1])','$($splitarray[2])','$($splitarray[3])','$($splitarray[4])','$($splitarray[5])','$($collection_time)')"


   $i++


        } ##while loop



#Close SSH Session on Server
Remove-SSHSession -SSHSession (Get-SSHSession)

} ##foreach loop