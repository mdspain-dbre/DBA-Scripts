<#
.SYNOPSIS
  Inventory Cloud SQL + AlloyDB instances across GCP projects and write a CSV.

.DESCRIPTION
  Read-only (only gcloud list/describe calls). For every project, lists each
  Cloud SQL and AlloyDB instance and emits five columns:
    project       - GCP project id
    instance_name - Cloud SQL instance name; AlloyDB shown as <cluster>/<instance>
    machine_type  - Cloud SQL settings.tier (e.g. db-g1-small); AlloyDB
                    machineConfig.machineType (e.g. n2-highmem-2), falling back to
                    "<n>-vCPU" from cpuCount on older instances without a machineType.
    db_type       - cloudsql | alloydb
    engine        - postgres | mysql | sqlserver (AlloyDB is always postgres)
  Cloud SQL read replicas / external masters report an empty tier -> "-".

  Writes a CSV and a Markdown table (defaults: db-inventory.csv / db-inventory.md
  beside this script) and prints a table to the console.

.PARAMETER Projects
  GCP project ids to scan. Defaults to the inscape portfolio + dre-dev set.

.PARAMETER OutputCsv
  Destination CSV path. Defaults to db-inventory.csv next to this script.

.PARAMETER OutputMarkdown
  Destination Markdown path. Defaults to db-inventory.md next to this script.

.EXAMPLE
  ./Get-DbInventory.ps1

.EXAMPLE
  ./Get-DbInventory.ps1 -Projects vz-dre-dev -OutputCsv ./dre-only.csv
#>

[CmdletBinding()]
param(
    # GCP project ids to scan.
    [string[]]$Projects = @(
        'vz-inscape-portfolio-dev',
        'vz-inscape-portfolio-qa',
        'vz-inscape-portfolio-stage',
        'vz-inscape-portfolio-prod',
        'vz-dre-dev'
    ),

    # Destination CSV path.
    [string]$OutputCsv = (Join-Path $PSScriptRoot 'db-inventory.csv'),

    # Destination Markdown path.
    [string]$OutputMarkdown = (Join-Path $PSScriptRoot 'db-inventory.md')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    throw "gcloud not found on PATH. Install the Google Cloud SDK: brew install --cask google-cloud-sdk"
} # end if (-not gcloud)

# Map a Cloud SQL databaseVersion (e.g. POSTGRES_18, MYSQL_8_4) to a short engine name.
function Get-Engine {
    param([string]$Version)
    switch -Wildcard ($Version) {
        'POSTGRES*'  { 'postgres' }
        'MYSQL*'     { 'mysql' }
        'SQLSERVER*' { 'sqlserver' }
        default      { if ($Version) { $Version } else { '-' } }
    }
} # end function Get-Engine

# Build a padded Markdown table row: '| c1 | c2 | ... |', each cell PadRight to width.
function Format-MdRow {
    param(
        [string[]]$Cells,
        [int[]]$Widths
    )
    $padded = for ($c = 0; $c -lt $Cells.Count; $c++) { $Cells[$c].PadRight($Widths[$c]) }
    '| ' + ($padded -join ' | ') + ' |'
} # end function Format-MdRow

$rows = New-Object System.Collections.Generic.List[object]

foreach ($p in $Projects) {
    # Skip projects we can't see rather than aborting the whole run.
    & gcloud projects describe $p 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0)
        {
            Write-Host "[skip] $p inaccessible" -ForegroundColor DarkGray
            continue
        }  # end if ($LASTEXITCODE -ne 0) [project describe]

    Write-Host "Scanning $p ..." -ForegroundColor DarkCyan

    <#######################################
     #######################################
       Cloud SQL instances 
     #######################################  
     #######################################>
    $sqlJson = (& gcloud sql instances list --project=$p --format=json 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $sqlJson)
        {
            foreach ($i in ($sqlJson | ConvertFrom-Json)) {
                $tier = if ($i.settings -and $i.settings.tier) { $i.settings.tier } else { '-' }
                $rows.Add([pscustomobject]@{
                    project       = $p
                    instance_name = $i.name
                    machine_type  = $tier
                    db_type       = 'cloudsql'
                    engine        = Get-Engine $i.databaseVersion
                })
            }
        }  # end if (cloudsql list ok)

    <#######################################
     #######################################
       AlloyDB clusters + instances 
     #######################################  
     #######################################>
    $cluJson = (& gcloud alloydb clusters list --project=$p --region=- --format=json 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $cluJson)
        {
            foreach ($c in ($cluJson | ConvertFrom-Json)) {
                # cluster resource name: projects/<p>/locations/<region>/clusters/<cluster>
                $region  = ($c.name -replace '.*/locations/([^/]+)/.*', '$1')
                $cluster = ($c.name -replace '.*/clusters/([^/]+)$', '$1')

                $instJson = (& gcloud alloydb instances list --cluster=$cluster --region=$region --project=$p --format=json 2>$null) -join "`n"
                if ($LASTEXITCODE -ne 0 -or -not $instJson) { continue }

                foreach ($ai in ($instJson | ConvertFrom-Json)) {
                    $iname = ($ai.name -replace '.*/instances/([^/]+)$', '$1')
                    # AlloyDB machine config: prefer the named machineType (e.g. n2-highmem-2),
                    # fall back to cpuCount for older instances that only report vCPUs.
                    $mtype = if ($ai.machineConfig.machineType) { $ai.machineConfig.machineType } else { "$($ai.machineConfig.cpuCount)-vCPU" }
                    $rows.Add([pscustomobject]@{
                        project       = $p
                        instance_name = "$cluster/$iname"
                        machine_type  = $mtype
                        db_type       = 'alloydb'
                        engine        = 'postgres'
                    })
                }
            }
        }  # end if (alloydb list ok)
} # end foreach ($p in $Projects)

if ($rows.Count -eq 0)
    {
        Write-Warning "No instances found across: $($Projects -join ', ')"
        return
    }  # end if ($rows.Count -eq 0)

# Drop any existing outputs first, then recreate them fresh.
Remove-Item -Path $OutputCsv, $OutputMarkdown -Force -ErrorAction SilentlyContinue

$rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
Write-Host "wrote $OutputCsv ($($rows.Count) rows)" -ForegroundColor Green

# Markdown table -- columns padded to a uniform width so the raw source lines up.
# Pipe chars in a cell are escaped so they don't split columns.
$mdHeaders = @('Project','Instance Name','Machine Type','DB Type','Engine')
$mdData = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $mdData.Add(@(
        ($r.project       -replace '\|','\|'),
        ($r.instance_name -replace '\|','\|'),
        ($r.machine_type  -replace '\|','\|'),
        ($r.db_type       -replace '\|','\|'),
        ($r.engine        -replace '\|','\|')
    ))
}

# Column width = longest cell (header included) per column.
$mdWidths = for ($c = 0; $c -lt $mdHeaders.Count; $c++) {
    $w = $mdHeaders[$c].Length
    foreach ($row in $mdData) {
        if ($row[$c].Length -gt $w) { $w = $row[$c].Length }
    }
    $w
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# GCP DB Inventory -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$md.Add('')
$md.Add("_$($rows.Count) instance(s) across $($Projects.Count) project(s)._")
$md.Add('')
$md.Add((Format-MdRow -Cells $mdHeaders -Widths $mdWidths))
$mdSep = for ($c = 0; $c -lt $mdWidths.Count; $c++) { '-' * $mdWidths[$c] }
$md.Add('| ' + ($mdSep -join ' | ') + ' |')
foreach ($row in $mdData) {
    $md.Add((Format-MdRow -Cells $row -Widths $mdWidths))
}
$md | Set-Content -Path $OutputMarkdown -Encoding utf8 -Force
Write-Host "wrote $OutputMarkdown" -ForegroundColor Green

$rows | Format-Table -AutoSize
