$DebugPreference = "SilentlyContinue"


 
Install-Module SQLSERver -AllowClobber 

Import-Module SqlServer -DisableNameChecking




$scriptpath = 'C:\Temp\DBStats.sql'

$DBPath = 'SqlServer:\SQL\DRE-Jumpbox\default\databases\DBSTats'
 
Set-Location $DBPath\Schemas


$schemas = Get-ChildItem


foreach($schema in $schemas)
{
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--' + $schema.name | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    $schema.script()  | Out-File $scriptpath -Append -Encoding utf8
    'GO' | Out-File $scriptpath -Append -Encoding utf8


}






write-host 'enum tables\indexes\constraints\extended prop\triggers' -BackgroundColor green -ForegroundColor Black


 


Set-Location $DBPath\tables


 






$tables = get-childitem


 


foreach ($table in $tables)
{
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--' + $table.name | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    $table.enumscript() | Out-File $scriptpath -Append -Encoding utf8


 


}


 


write-host 'types' -BackgroundColor green -ForegroundColor Black


 


Set-Location $DBPath\userdefinedtabletypes


 


$types = get-childitem


 


foreach ($type in $types)
{
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--' + $type.name | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    $type.script() | Out-File $scriptpath -Append -Encoding utf8


    'GO' | Out-File $scriptpath -Append -Encoding utf8


 


}


 


write-host 'sps' -BackgroundColor green -ForegroundColor Black


 


Set-Location $DBPath\storedprocedures


 


$sps = get-childitem


 


foreach ($sp in $sps)
{
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--' + $sp.name | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    $sp.script() | Out-File $scriptpath -Append -Encoding utf8


    'GO' | Out-File $scriptpath -Append -Encoding utf8


 


}


 


write-host 'functions' -BackgroundColor green -ForegroundColor Black


 


Set-Location $DBPath\userdefinedfunctions


 


$udfs = get-childitem


 


foreach ($udf in $udfs)
{
    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--' + $udf.name | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    '--------------------------' | Out-File $scriptpath -Append -Encoding utf8


    $udf.script() | Out-File $scriptpath -Append -Encoding utf8


    'GO' | Out-File $scriptpath -Append -Encoding utf8


 


}


 


Write-Host 'remove ANSI Default text...' -ForegroundColor white -BackgroundColor Blue


 


$allTheText = [System.Io.File]::ReadAllText($scriptpath)


 


$allTheText -replace 'SET ANSI_NULLS ON', 'GO' -replace 'SET QUOTED_IDENTIFIER ON', '' | Set-Content $scriptpath  


    
