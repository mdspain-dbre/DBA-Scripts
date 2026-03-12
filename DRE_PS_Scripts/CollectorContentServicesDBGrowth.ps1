Import-Module DBATools

Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register

$ErrorActionPreference = 'Stop'

try {
    $Repo = "DRE-Jumpbox"
    $CollectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Get Content Services SQL Server instances from Servers.Servers
    $ServerQuery = "SELECT Servername FROM Servers.Servers WHERE decomm = 0 AND is_sql = 1 AND is_rds = 1"
    $Servers = Invoke-DbaQuery -SqlInstance $Repo -Database DBStats -Query $ServerQuery

    foreach ($Server in $Servers) {
        $SQLInstance = $Server.Servername

        Write-Host "Collecting DB space from $SQLInstance..."

        $Results = Get-DbaDbSpace -SqlInstance $SQLInstance -ExcludeDatabase 'Model'|
            Select-Object @{Name = 'ServerName'; Expression = { $SQLInstance } },
                @{Name = 'DatabaseName'; Expression = { $_.Database } },
                @{Name = 'FileName'; Expression = { $_.FileName } },
                @{Name = 'FileType'; Expression = { $_.FileType } },
                @{Name = 'FileSizeGB'; Expression = { [math]::Round($_.FileSize.Gigabyte, 2) } },
                @{Name = 'UsedSpaceGB'; Expression = { [math]::Round($_.UsedSpace.Gigabyte, 2) } },
                @{Name = 'FreeSpaceGB'; Expression = { [math]::Round($_.AvailableSpace.Gigabyte, 2) } },
                @{Name = 'FreeSpacePct'; Expression = { [math]::Round($_.PercentUsed, 2) } },
                @{Name = 'CollectionTime'; Expression = { $CollectionTime } }

        if ($Results) {
            $Results | Write-DbaDbTableData -SqlInstance $Repo -Database DBStats -Table "Collector.ContentServicesDBGrowth" -AutoCreateTable
        }

        Write-Host "Completed $SQLInstance"
    }

    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
