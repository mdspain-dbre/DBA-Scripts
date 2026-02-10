<#
.SYNOPSIS
    Monitors MongoDB drive space usage and sends Slack alerts when thresholds are exceeded.

.DESCRIPTION
    This script queries the DBStats database to check MongoDB server drive space usage.
    It executes the Alert.MongoDbDriveSpace stored procedure with a configurable threshold.
    If any servers exceed the threshold (default 88%), a Slack alert is sent to the 
    cpie-dre-alerts channel with details about the affected server(s).

    Alert includes:
    - Hostname and IP address
    - Mount point affected
    - Current used percentage
    - Available space remaining
    - Collection timestamp

.NOTES
    Author: Michael DSpain
    Requires: dbatools module
    Slack Channel: cpie-dre-alerts
    Threshold: 88% (configured in stored procedure call)

.EXAMPLE
    .\MongoDBDriveSpaceAlert.ps1
    Checks all MongoDB servers and alerts if any exceed 88% disk usage.
#>

#region Script Configuration
$DebugPreference = "SilentlyContinue"
$InformationPreference = 'Continue'
$ErrorActionPreference = "stop"  # Fail fast on errors
#endregion

#region Variables
# SQL Server instance containing the DBStats database and Alert procedures
$Repo = "DRE-Jumpbox"
#endregion

try {
    #region Slack Configuration
    # Webhook URL for cpie-dre-alerts Slack channel
    $webhookUrl = "<enter slack webhook url here>"
    #endregion

    #region Query Drive Space Data
    # Execute stored procedure to get servers exceeding threshold
    # @threshold = 88 means alert when drive is 88% or more full
    $MongoDriveSpace = Invoke-DbaQuery -SqlInstance $Repo -Database DBStats -Query "Execute Alert.MongoDbDriveSpace @threshold = 88" -EnableException -ErrorAction Stop
    #endregion

    #region Build Alert Message
    # Format the alert message with server details
    $rawBody = "HostName : $($MongoDriveSpace.HostName)....
            IP : $($MongoDriveSpace.IP)....
            Mount : $($MongoDriveSpace.Mount)....
            Used Percentage : $($MongoDriveSpace.UsedPercentage)%....
            Space Available : $($MongoDriveSpace.Available)....
            Collection Time : $($MongoDriveSpace.CollectionTime)...."
    #endregion

    #region Send Slack Alert
    # Only send alert if servers were returned (exceeding threshold)
    if ($MongoDriveSpace -ne $null) {
        # Build Slack attachment with red color for urgency
        $attachment = @{
            color   = "#FF0000"                                      # Red color bar
            pretext = "MongoDB DriveSpace: Used Percentage Above Threshold"
            text    = "$($rawBody)"
            footer  = "*Friendly Neighborhood DRE Team*"
            ts      = [math]::Round((Get-Date -UFormat %s))          # Unix timestamp
        }

        # Convert to JSON for Slack API
        $payload = @{
            attachments = @($attachment)
        } | ConvertTo-Json -Depth 3 -Compress

        # Send POST request to Slack webhook
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json"
    }
    else {
        # No servers exceeding threshold - no alert needed
        Write-Host 'No Drivespace issues' -ForegroundColor Yellow
    }
    #endregion

    # Success - exit with code 0 for SQL Agent job
    exit 0
}
catch [Exception] {
    # Log error and exit with code 1 to signal failure to SQL Agent
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
      
