<#
.SYNOPSIS
    Rotates MongoDB log files on Linux servers and removes old log files.

.DESCRIPTION
    This script connects to production Linux MongoDB servers via SSH and performs log maintenance:
    1. Queries Servers.MongoDB table to get list of production Linux servers (excluding arbiters)
    2. Establishes SSH sessions using a PEM key file
    3. Executes MongoDB logRotate command to rotate the current log
    4. Removes old log files (mongod.log.*) to free up disk space

    This helps prevent log files from consuming excessive disk space on MongoDB servers.

.NOTES
    Author: Michael DSpain
    Requires: posh-ssh module, dbatools module, SSH key file at D:\SSH_Keys\PS_SSHKey.pem
    Target: Linux MongoDB servers (production, non-arbiter)

.EXAMPLE
    .\CS_RotateMongologs.ps1
    Rotates logs on all production Linux MongoDB servers.
#>

#region Script Configuration
# Fail on any error - ensures job fails properly if issues occur
$ErrorActionPreference = 'Stop'
# Set to 'Continue' to enable debug output for troubleshooting
$DebugPreference = 'SilentlyContinue'
# Shows progression through the server loop
$InformationPreference = 'Continue'
#endregion

try {
    #region Module Import
    # posh-ssh: Provides SSH connectivity to Linux servers
    # dbatools: Provides SQL Server connectivity for querying server list
    Import-Module posh-ssh -ErrorAction Stop -Scope Local
    Import-Module dbatools -ErrorAction Stop -Scope Local
    #endregion

    #region Configuration Variables
    # SQL Server instance containing the Servers.MongoDB table
    $Repo = "DRE-Jumpbox"

    # Path to the SSH private key file for authentication
    $KeyFile = "D:\SSH_Keys\PS_SSHKey.pem"
    
    # SSH user account on Linux servers
    $User = "ubuntu"
    #endregion
    
    #region Query MongoDB Servers
    # Get production Linux MongoDB servers (excluding arbiters which don't have data logs)
    $MongoProdQuery = "SELECT ServerID, IP,Hostname FROM Servers.MongoDB WHERE is_prod = 1 and is_linux = 1  and is_arbitor = 0"
    $LinuxServers = Invoke-DbaQuery -SqlInstance dre-jumpbox -Database DBStats -Query $MongoProdQuery -ErrorAction Stop
    #endregion

    #region Process Each Server
    foreach ($lserver in $LinuxServers) {

        Write-Information "working on $($lserver.Hostname)"

        # Establish SSH session using key-based authentication
        # Note: A dummy password is required by PSCredential but not used (key auth only)
        $SSH_Session = New-SSHSession -ComputerName $($lserver.IP) -KeyFile $KeyFile -Credential (
            New-Object System.Management.Automation.PSCredential($User,(ConvertTo-SecureString "dummy" -AsPlainText -Force))
        ) -ErrorAction Stop -AcceptKey

        # Define MongoDB commands
        # logRotate: Tells MongoDB to close current log and start a new one
        $RotateLogCommand = "mongo --quiet --eval 'db.adminCommand( { logRotate: 1 } )'"
        # Remove old rotated log files to free disk space (mongod.log.2024-01-01T00-00-00, etc.)
        $RemoveLogFilesCommand = 'sudo rm /mnt/data/log/mongod.log.*'
       
        # Step 1: Rotate the current log file
        Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command $RotateLogCommand -ErrorAction Stop
        
        # Step 2: Wait for log rotation to complete before removing old files
        Start-Sleep -Seconds 5
        
        # Step 3: Remove old rotated log files
        Invoke-SSHCommand -SessionId $SSH_Session.SessionId -Command $RemoveLogFilesCommand -ErrorAction Stop
        
        # Clean up SSH session to free resources
        Remove-SSHSession -SessionId $SSH_Session.SessionId -ErrorAction SilentlyContinue | Out-Null

    }
    #endregion
    
    # Success - exit with code 0 for SQL Agent job
    exit 0
}
catch {
    # Log error and exit with code 1 to signal failure to SQL Agent
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
