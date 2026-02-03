Get-DbaDatabase -SqlInstance dre-jumpbox -Database DBStats | Export-DbaScript -FilePath C:\Temp\DBStats_DBSchema.sql

$tables = Get-DbaDbTable -SqlInstance dre-jumpbox -Database DBStats 

foreach($table in $tables)
    {$table | Export-DbaScript  -FilePath C:\Temp\DBStats_Table_$($table.schema)_$($table.name).sql}


$SPs = Get-DbaDbStoredProcedure -SqlInstance dre-jumpbox -Database DBStats -ExcludeSystemSp

foreach($SP in $SPs)
    {$SP |  Export-DbaScript  -FilePath C:\Temp\DBStats_SP_$($sp.schema)_$($sp.name).sql}


$Schemas = Get-DbaDbSchema -SqlInstance dre-jumpbox -Database DBStats 

foreach($Schema in $Schemas)
    {$Schema |  Export-DbaScript  -FilePath C:\Temp\DBStats_Schema_$($Schema.name).sql}

