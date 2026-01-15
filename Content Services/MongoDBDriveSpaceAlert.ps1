##Index\Stats Rebuild Webhook
$DebugPreference = "SilentlyContinue"
$InformationPreference = 'Continue'
$ErrorActionPreference = "stop"

##Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register

$Repo = "DRE-Jumpbox"

try {	


##Slack Channel Webhook  cpie-dre-alerts
$webhookUrl = "<enter slack webhook url here>"


$MongoDriveSpace = Invoke-DbaQuery -SqlInstance $Repo -Database DBStats -Query "Execute Alert.MongoDbDriveSpace @threshold = 88" -EnableException -ErrorAction Stop

##Instance where we get the index and stats maint that was completed
$rawBody = "HostName : $($MongoDriveSpace.HostName)....
            IP : $($MongoDriveSpace.IP)....
            Mount : $($MongoDriveSpace.Mount)....
            Used Percentage : $($MongoDriveSpace.UsedPercentage)%....
            Space Available : $($MongoDriveSpace.Available)....
            Collection Time : $($MongoDriveSpace.CollectionTime)...."


#Determine if a message needs to be sent
if($MongoDriveSpace -ne $null)
    {
# Define the attachment
$attachment = @{
    ##fallback = "This is fallback text for unsupported clients"
    color = "#FF0000"
    pretext = "MongoDB DriveSpace: Used Percentage Above Threshold"
    text = "$($rawBody)"
    footer = "*Friendly Neighborhood DRE Team*"
    ts = [math]::Round((Get-Date -UFormat %s))  # Unix timestamp
}

# Construct the payload
$payload = @{
    attachments = @($attachment)
} | ConvertTo-Json -Depth 3 -Compress

# Send the POST request
Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json"

}##if block
  else
    {write-host 'No Drivespace issues ' -ForegroundColor Yellow
    }

    # If everything succeeds
    exit 0

} ##Try Block 
    catch [Exception] 
    {

    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1  # Causes SQL Agent job to fail
    }
      
