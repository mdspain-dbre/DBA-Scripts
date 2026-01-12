##Index Rebuild Webhook
$DebugPreference = "SilentlyContinue"
$InformationPreference = 'Continue'
$ErrorActionPreference = "stop"

Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register

try {	


$webhookUrl = "<enter webhook URL here>"
$SQLInstance = "<enter prodsql1 instance name>"

##Finding Index Rebuilds for All DBs with Harmony excluded
$RebuildIndexNotHarmonyQuery = "select  Cast(Count(*)as varchar(6))+ ' Index(es) Rebuilt in '+'*'+DatabaseName+'*'+' Database `n'
from dbo.CommandLog
where CommandType = 'ALTER_INDEX'
Group By DatabaseName"

##Query the instace for the work done 
$RebuildIndexNotHarmony = Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query $RebuildIndexNotHarmonyQuery -EnableException

#Determine if a message needs to be sent
if($RebuildIndexNotHarmony)
    {

# Define the attachment
$attachment = @{
    ##fallback = "This is fallback text for unsupported clients"
    color = "good"
    pretext = "Content Services Index Maint Complete:"
    text = "$($RebuildIndexNotHarmony.Column1)"
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
    {write-host 'No Rebuilds to send to slack' -ForegroundColor Yellow
    }


<##################################
##################################
Harmony DBs
##################################
##################################>

##Finding Index Rebuilds for Harmony
$RebuildIndexHarmonyQuery = "Select Cast(Count(*)as varchar(6))+ ' Index(es) Rebuilt in *Harmony* Database'
from IndexMaint.HarmonyIndexes
where RebuildStatus = 1 and CollectionTime > getdate() -1"

$RebuildIndexHarmony =Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query $RebuildIndexHarmonyQuery -EnableException

#Determine if a message needs to be sent
if($RebuildIndexHarmony.Column1 -ne '0 Index(es) Rebuilt in *Harmony* Database')
    {
$attachment = @{
    ##fallback = "This is fallback text for unsupported clients"
    color = "good"
    pretext = "Content Services Index Maint Complete:"
    text = "$($RebuildIndexHarmony.Column1)"
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
    {write-host 'No Harmony Rebuilds to send to slack' -ForegroundColor Yellow
    }

} ##Try Block 
    catch [Exception] 
    {


            Write-Host -------------  Failure ----------------  -BackgroundColor blue -ForegroundColor Yellow
            $errormessage = $Error[0].Exception.Message -replace "'", ""  
            write-host $errormessage  -foreground red -BackgroundColor Yellow
    }
      

