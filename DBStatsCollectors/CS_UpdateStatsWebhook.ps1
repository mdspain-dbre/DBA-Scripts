##Index\Stats Rebuild Webhook
$DebugPreference = "SilentlyContinue"
$InformationPreference = 'Continue'
$ErrorActionPreference = "stop"

Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register


try {	


##Slack Channel Webhook  cpie-collab-content-svcs-data channel
$webhookUrl = "<enter webhook URL here>"

##Instance where we get the index and stats maint that was completed
$SQLInstance = '<>enter prodsql1 instance name>'


<##################################
##################################
Harmony DB Only
Execute 8AM Thursday and Saturday
##################################
##################################>

##removes rows from previous runs
Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query "delete from [dbo].[Stats_Log] where datediff(hour, finish_time,getdate()) > 24"


##Finding Stats Updated for Harmony
$UpDatStatsHarmonyQuery = "select Cast(Count(*) as varchar(5)) + ' Stats Updated in the *Harmony* Database' 
from dba.dbo.Stats_Log"

##Query the instace for the work done 
$UpdateStatsHarmony = Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query $UpDatStatsHarmonyQuery -EnableException


#Determine if a message needs to be sent
if($UpdateStatsHarmony.Column1 -ne '0 Stats Updated in the *Harmony* Database')
    {
# Define the attachment
$attachment = @{
    ##fallback = "This is fallback text for unsupported clients"
    color = "good"
    pretext = "Content Services Statistics Maint Complete:"
    text = "$($UpdateStatsHarmony.Column1)"
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
    {write-host 'No Harmony Stats Update to send to slack' -ForegroundColor Yellow
    }

<##################################
##################################
All other DBs
Execute 8AM Thursday and Saturday
##################################
##################################>

##Finding Index Rebuilds for Harmony
$UpdateStatsExcludeHarmonyQuery = "select Cast(Count(*) as varchar(5)) + ' Stat(s) Updated in '+'*'+DatabaseName+'*'+' Database `n' 
from 
dba.dbo.CommandLog
where CommandType = 'UPDATE_STATISTICS' and StartTime > getdate() -1
Group by DatabaseName"

$UpdateStatsExcludeHarmony =Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query $UpdateStatsExcludeHarmonyQuery -EnableException

#Determine if a message needs to be sent
if($UpdateStatsExcludeHarmony)
    {


$attachment = @{
    ##fallback = "This is fallback text for unsupported clients"
    color = "good"
    pretext = "Content Services Statistics Maint Complete:"
    text = "$($UpdateStatsExcludeHarmony.Column1)"
    footer = "*Friendly Neighborhood DRE Team*"
    ts = [math]::Round((Get-Date -UFormat %s))  # Unix timestamp
}

# Construct the payload
$payload = @{
    attachments = @($attachment)
} | ConvertTo-Json -Depth 3 -Compress

# Send the POST request
Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json"

##delete commandlog 
Invoke-DbaQuery -SQLInstance $SQLInstance -Database DBA -Query "Delete dba.dbo.CommandLog"

}##if block
  else
    {write-host 'No Stats Update Exlude Harmony to send to slack' -ForegroundColor Red
    }

} ##Try Block 
    catch [Exception] 
    {


            Write-Host -------------  Failure ----------------  -BackgroundColor blue -ForegroundColor Yellow
            $errormessage = $Error[0].Exception.Message -replace "'", ""  
            write-host $errormessage  -foreground red -BackgroundColor Yellow
    }
      
