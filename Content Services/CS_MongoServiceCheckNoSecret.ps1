<#
.SYNOPSIS
    Checks MongoDB Windows service status across multiple servers and sends Slack alerts if issues are detected.

.DESCRIPTION
    This script queries the Servers.MongoDB table in the DBStats database to retrieve a list of 
    production Windows MongoDB servers. It then uses CIM (Common Information Model) to check the 
    status of the MongoDB service on each server. If any services are not running, not found, or 
    unreachable, an alert is sent to the cpie-dre-alerts Slack channel.

    CIM is the modern replacement for WMI and provides better performance and PowerShell remoting support.

.PARAMETER ServiceName
    The name of the Windows service to check. Default: "MongoDB"

.PARAMETER SqlInstance
    The SQL Server instance containing the Servers.MongoDB table. Default: "dre-jumpbox"

.PARAMETER Database
    The database containing the Servers.MongoDB table. Default: "DBStats"

.PARAMETER SlackWebhookUrl
    The Slack webhook URL for the cpie-dre-alerts channel.

.NOTES
    Author: Michael DSpain
    Requires: dbatools module, CIM/WinRM access to target servers
    Created: February 2026

.EXAMPLE
    .\CS_MongoServiceCheck.ps1
    Runs the script with default parameters.

.EXAMPLE
    .\CS_MongoServiceCheck.ps1 -ServiceName "MongoDB" -SqlInstance "dre-jumpbox"
    Runs the script with specified parameters.
#>

param(
    [string]$ServiceName = "MongoDB",
    [string]$SqlInstance = "dre-jumpbox",
    [string]$Database = "DBStats",
    [string]$SlackWebhookUrl = "<enter webhook URL>"
)

# Query MongoDB Servers from Database
# Retrieve list of active production Windows MongoDB servers from the Servers.MongoDB table
# Filters: is_prod = 1 (production only), is_windows = 1 (Windows servers only)
$query = @"
SELECT HostName 
FROM Servers.MongoDB 
WHERE is_prod = 1
  AND is_windows = 1
"@

$servers = Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query $query

# Exit if no servers are returned from the database
if (-not $servers) {
    Write-Error "No MongoDB servers found in Servers.MongoDB"
    exit 1
} 
# end region


# Check Service Status on Each Server
# Initialize array to collect servers with issues for Slack alerting
$alertServers = @()

foreach ($server in $servers) {
    $ComputerName = $server.HostName
    
    try {
        # Create a CIM session to the remote server
        # CIM sessions use WS-Management (WinRM) for remote connectivity
        $cimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
        
        # Define parameters for querying the Win32_Service class
        # Filter by service name to get only the MongoDB service
        $cimParams = @{
            ClassName  = 'Win32_Service'
            Filter     = "Name='$ServiceName'"
            CimSession = $cimSession
        }

        # Query the service information from the remote server
        $service = Get-CimInstance @cimParams -ErrorAction Stop

        # Handle case where service is not installed on the server
        if (-not $service) {
            Write-Error "Service '$ServiceName' not found on $ComputerName"
            $alertServers += [PSCustomObject]@{
                ComputerName = $ComputerName
                Status       = "Service Not Found"
            }
            continue
        }

        # Build result object with service details
        $result = [PSCustomObject]@{
            ComputerName = $ComputerName
            ServiceName  = $service.Name
            DisplayName  = $service.DisplayName
            Status       = $service.State          # Running, Stopped, Paused, etc.
            StartMode    = $service.StartMode      # Auto, Manual, Disabled
            ProcessId    = $service.ProcessId      # PID of the running service
            Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        # Output the result to the pipeline
        Write-Output $result 

        # Check if service is not running and add to alert list
        if ($service.State -ne 'Running') {
            Write-Warning "Service '$ServiceName' is not running on $ComputerName. Current status: $($service.State)"
            $alertServers += [PSCustomObject]@{
                ComputerName = $ComputerName
                Status       = $service.State
            }
        }
    }
    catch {
        # Handle connection failures or other errors
        Write-Error "Failed to get service status for '$ServiceName' on $ComputerName. Error: $_"
        $alertServers += [PSCustomObject]@{
            ComputerName = $ComputerName
            Status       = "Error: $_"
        }
    }
    finally {
        # Clean up CIM session to free resources
        # Always remove session even if errors occurred
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
            $cimSession = $null
        }
    }
}
# end region


# Send Slack Alert for Failed Services
# Only send alert if there are servers with issues
if ($alertServers.Count -gt 0) {
    # Format alert message with warning emoji and server details
    $alertMessage = ($alertServers | ForEach-Object { ":warning: *$($_.ComputerName)*: $($_.Status)" }) -join "`n"
    
    # Build Slack attachment with red "danger" color for visibility
    $attachment = @{
        color   = "danger"                                    # Red color bar
        pretext = ":rotating_light: MongoDB Service Alert"   # Header text
        text    = $alertMessage                               # Server details
        footer  = "*Friendly Neighborhood DRE Team*"          # Footer signature
        ts      = [math]::Round((Get-Date -UFormat %s))       # Unix timestamp
    }

    # Convert payload to JSON for Slack API
    $payload = @{
        attachments = @($attachment)
    } | ConvertTo-Json -Depth 3 -Compress

    # Send POST request to Slack webhook
    try {
        Invoke-RestMethod -Uri $SlackWebhookUrl -Method Post -Body $payload -ContentType "application/json"
        Write-Host "Slack alert sent to cpie-dre-alert channel" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to send Slack alert: $_"
    }
}
# end region

