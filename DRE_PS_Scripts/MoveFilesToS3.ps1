<#
.SYNOPSIS
    Moves files from a Windows drive to an AWS S3 bucket.

.DESCRIPTION
    Uploads files from a local Windows path to an S3 bucket with progress reporting
    and error handling. Optionally deletes source files after successful upload.

.PARAMETER SourcePath
    The local path to the file or folder to upload.

.PARAMETER BucketName
    The name of the target S3 bucket.

.PARAMETER KeyPrefix
    The S3 key prefix (folder path) where files will be uploaded.

.PARAMETER DeleteAfterUpload
    If specified, deletes source files after successful upload.

.PARAMETER ProfileName
    AWS credential profile name. Defaults to 'default'.

.PARAMETER Region
    AWS region for the S3 bucket. Defaults to 'us-east-1'.

.EXAMPLE
    .\MoveFilesToS3.ps1 -SourcePath "D:\Backups" -BucketName "my-bucket" -KeyPrefix "backups/2026/"

.EXAMPLE
    .\MoveFilesToS3.ps1 -SourcePath "D:\Logs\app.log" -BucketName "my-bucket" -KeyPrefix "logs/" -DeleteAfterUpload
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [Parameter(Mandatory = $false)]
    [string]$KeyPrefix = "",

    [Parameter(Mandatory = $false)]
    [switch]$DeleteAfterUpload,

    [Parameter(Mandatory = $false)]
    [string]$ProfileName = "default",

    [Parameter(Mandatory = $false)]
    [string]$Region = "us-east-1"
)

#region Functions

function Install-RequiredModules {
    <#
    .SYNOPSIS
        Ensures AWS.Tools.S3 module is installed.
    #>
    if (-not (Get-Module -ListAvailable -Name AWS.Tools.S3)) {
        Write-Host "Installing AWS.Tools.S3 module..." -ForegroundColor Yellow
        try {
            Install-Module -Name AWS.Tools.S3 -Force -Scope CurrentUser -ErrorAction Stop
            Write-Host "AWS.Tools.S3 module installed successfully." -ForegroundColor Green
        }
        catch {
            throw "Failed to install AWS.Tools.S3 module: $_"
        }
    }
    Import-Module AWS.Tools.S3 -ErrorAction Stop
}

function Test-S3BucketAccess {
    <#
    .SYNOPSIS
        Validates access to the specified S3 bucket.
    #>
    param(
        [string]$Bucket,
        [string]$Profile,
        [string]$BucketRegion
    )
    
    try {
        $null = Get-S3Bucket -BucketName $Bucket -ProfileName $Profile -Region $BucketRegion -ErrorAction Stop
        return $true
    }
    catch {
        throw "Cannot access bucket '$Bucket'. Verify bucket exists and credentials have permission: $_"
    }
}

function Upload-FileToS3 {
    <#
    .SYNOPSIS
        Uploads a single file to S3.
    #>
    param(
        [string]$FilePath,
        [string]$Bucket,
        [string]$Key,
        [string]$Profile,
        [string]$BucketRegion
    )
    
    $fileInfo = Get-Item $FilePath
    $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
    
    Write-Host "  Uploading: $($fileInfo.Name) ($fileSizeMB MB) -> s3://$Bucket/$Key" -ForegroundColor Cyan
    
    try {
        Write-S3Object -BucketName $Bucket `
                       -File $FilePath `
                       -Key $Key `
                       -ProfileName $Profile `
                       -Region $BucketRegion `
                       -ErrorAction Stop
        
        return @{
            Success = $true
            FilePath = $FilePath
            S3Key = $Key
            SizeBytes = $fileInfo.Length
        }
    }
    catch {
        return @{
            Success = $false
            FilePath = $FilePath
            S3Key = $Key
            Error = $_.Exception.Message
        }
    }
}

#endregion Functions

#region Main Script

$ErrorActionPreference = "Stop"
$startTime = Get-Date

Write-Host "`n========================================" -ForegroundColor White
Write-Host "  Move Files to S3 Bucket" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Source:      $SourcePath"
Write-Host "Bucket:      $BucketName"
Write-Host "Key Prefix:  $(if ($KeyPrefix) { $KeyPrefix } else { '(root)' })"
Write-Host "Delete After Upload: $DeleteAfterUpload"
Write-Host "----------------------------------------`n"

# Install/Import required modules
Install-RequiredModules

# Initialize AWS profile
try {
    Set-AWSCredential -ProfileName $ProfileName -ErrorAction Stop
    Write-Host "Using AWS profile: $ProfileName" -ForegroundColor Green
}
catch {
    throw "Failed to set AWS credentials. Run 'Set-AWSCredential -AccessKey <key> -SecretKey <secret> -StoreAs $ProfileName' first. Error: $_"
}

# Validate bucket access
Write-Host "Validating bucket access..." -ForegroundColor Yellow
Test-S3BucketAccess -Bucket $BucketName -Profile $ProfileName -BucketRegion $Region
Write-Host "Bucket access confirmed.`n" -ForegroundColor Green

# Get files to upload
$isDirectory = (Get-Item $SourcePath).PSIsContainer
if ($isDirectory) {
    $files = Get-ChildItem -Path $SourcePath -File -Recurse
    $basePath = (Get-Item $SourcePath).FullName
}
else {
    $files = @(Get-Item $SourcePath)
    $basePath = Split-Path $SourcePath -Parent
}

if ($files.Count -eq 0) {
    Write-Host "No files found at source path." -ForegroundColor Yellow
    exit 0
}

$totalFiles = $files.Count
$totalSizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
$totalSizeMB = [math]::Round($totalSizeBytes / 1MB, 2)

Write-Host "Found $totalFiles file(s) to upload ($totalSizeMB MB total)`n" -ForegroundColor White

# Upload files
$results = @{
    Successful = @()
    Failed = @()
}

$currentFile = 0
foreach ($file in $files) {
    $currentFile++
    Write-Host "[$currentFile/$totalFiles]" -ForegroundColor White -NoNewline
    
    # Calculate S3 key
    $relativePath = $file.FullName.Substring($basePath.Length).TrimStart('\', '/')
    $s3Key = if ($KeyPrefix) {
        "$($KeyPrefix.TrimEnd('/'))/$relativePath"
    }
    else {
        $relativePath
    }
    # Normalize path separators for S3
    $s3Key = $s3Key -replace '\\', '/'
    
    $uploadResult = Upload-FileToS3 -FilePath $file.FullName `
                                    -Bucket $BucketName `
                                    -Key $s3Key `
                                    -Profile $ProfileName `
                                    -BucketRegion $Region
    
    if ($uploadResult.Success) {
        $results.Successful += $uploadResult
        Write-Host "    [OK]" -ForegroundColor Green
    }
    else {
        $results.Failed += $uploadResult
        Write-Host "    [FAILED] $($uploadResult.Error)" -ForegroundColor Red
    }
}

# Delete source files if requested and all uploads succeeded
if ($DeleteAfterUpload -and $results.Failed.Count -eq 0) {
    Write-Host "`nDeleting source files..." -ForegroundColor Yellow
    foreach ($uploaded in $results.Successful) {
        try {
            Remove-Item -Path $uploaded.FilePath -Force -ErrorAction Stop
            Write-Host "  Deleted: $($uploaded.FilePath)" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "  Failed to delete: $($uploaded.FilePath) - $_" -ForegroundColor Red
        }
    }
}
elseif ($DeleteAfterUpload -and $results.Failed.Count -gt 0) {
    Write-Host "`nSkipping deletion - some uploads failed." -ForegroundColor Yellow
}

# Summary
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`n========================================" -ForegroundColor White
Write-Host "  Upload Summary" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Total Files:     $totalFiles"
Write-Host "Successful:      $($results.Successful.Count)" -ForegroundColor Green
Write-Host "Failed:          $($results.Failed.Count)" -ForegroundColor $(if ($results.Failed.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "Total Size:      $totalSizeMB MB"
Write-Host "Duration:        $([math]::Round($duration.TotalSeconds, 2)) seconds"
Write-Host "----------------------------------------`n"

if ($results.Failed.Count -gt 0) {
    Write-Host "Failed uploads:" -ForegroundColor Red
    foreach ($failure in $results.Failed) {
        Write-Host "  - $($failure.FilePath): $($failure.Error)" -ForegroundColor Red
    }
    exit 1
}

Write-Host "All files uploaded successfully!" -ForegroundColor Green
exit 0

#endregion Main Script
