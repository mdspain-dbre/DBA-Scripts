$ErrorActionPreference = 'Stop'
$installerUrl = 'https://fastdl.mongodb.org/tools/db/mongodb-database-tools-windows-x86_64-100.10.0.msi'
$installerPath = 'C:\Temp\mongodb-database-tools.msi'

New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
Write-Output 'Downloading MongoDB Database Tools...'
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

Write-Output 'Installing MongoDB Database Tools...'
Start-Process msiexec.exe -ArgumentList '/i', $installerPath, '/quiet', '/norestart' -Wait -NoNewWindow

$mongoToolsPath = 'C:\Program Files\MongoDB\Tools\100\bin'
if (Test-Path $mongoToolsPath) {
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if ($currentPath -notlike "*$mongoToolsPath*") {
        [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$mongoToolsPath", 'Machine')
        Write-Output 'Added to system PATH'
    }
}

$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
$ver = & mongorestore --version 2>&1 | Select-Object -First 1
Write-Output "Installed: $ver"
Remove-Item $installerPath -Force
Write-Output 'Done.'
