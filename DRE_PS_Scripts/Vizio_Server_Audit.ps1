$DebugPreference = "SilentlyContinue"
$ErrorActionPreference = "stop"

$repo = "localhost"
$servers = Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -Query "select serverid, servername from servers.servers 
WHERE decomm = 0 and is_SQL = 1 and is_rds = 0" 

Invoke-DbaQuery -SqlInstance $repo -database dbstats -query "TRUNCATE TABLE servers.DB_services"

$repodate = get-date

foreach($server in $servers){

 try{   

 Write-Host "Working on $($server.Servername)" -ForegroundColor White -BackgroundColor DarkGreen

$audit = Invoke-DbaQuery -SqlInstance $($server.servername) -Database master -Query "--DROP TEMP TABLE IF ALREADY EXISTS

if OBJECT_ID('tempdb..#audit')is not null
	drop table #audit
go 
--CREATE TEMP TABLE FOR SERVER AND DB RESULTS
 	
create table #audit
(Servername varchar(16)
,SQl_Server_Build_Version sql_variant
,SQL_Server_Edition sql_variant
,SQl_Server_PatchLevel sql_variant
,SQL_Product_level sql_variant
,Server_Collation sql_variant 
,Max_Server_Value Int
,Max_Server_Percentage float
,Optimize_for_AD_Hoc sql_variant
,RAM int
,max_dop int
,CostThreshold int
,tflags varchar(40)
)

--DETERMINE COLLATION OF SERVER AND VCLOUD DB

DECLARE @scol sql_variant
DECLARE @collation varchar(30)

SELECT @scol =SERVERPROPERTY('collation') 

declare @sqlproductlevel sql_variant
select @sqlproductlevel = SERVERPROPERTY('ProductUpdateLevel')

--DETERMINE AMOUNT OF PHYSICAL MEMORY BOX

DECLARE @physical FLOAT;
DECLARE @max FLOAT;
DECLARE @maxservermemvalue INT;


if object_id('tempdb..#phsyicalmem') is not null
drop table #phsyicalmem

CREATE TABLE #phsyicalmem
(mem_value float)

DECLARE @cmd VARCHAR(200);
IF NOT EXISTS
(
    SELECT *
    WHERE CONVERT(VARCHAR(128), SERVERPROPERTY('ProductVersion')) LIKE '9%'  --find max server mem on 2005 box
)
BEGIN
    
    SET @cmd
        = 'DECLARE @mem float; 
SELECT @mem = round(([total_physical_memory_kb] / 1024.0/1024.0),0,0)
	FROM [master].[sys].[dm_os_sys_memory]
SELECT @mem ';

INSERT INTO #phsyicalmem
(
    mem_value
)
EXECUTE (@cmd);

END;
ELSE
BEGIN
    SET @cmd
        = 'DECLARE @mem float;
SELECT @mem = ROUND((physical_memory_in_bytes/1024.0/1024.0/1024.0),0,0)
FROM sys.dm_os_sys_info WITH (NOLOCK) OPTION (RECOMPILE)
Select @mem';
    --PRINT @sql
 --   EXECUTE (@phsyical);
	
INSERT INTO #phsyicalmem
(
    mem_value
)
EXECUTE (@cmd);
END;

SELECT @physical = (SELECT  mem_value FROM #phsyicalmem)

--CONVERT MEMORY RESULT TO GBs
SELECT @max = CASE WHEN VALUE_IN_USE = 0 or value_in_use = 2147483647  THEN @physical
				else cast(value_in_use as float)/1024.0 END
	FROM [master].[sys].[configurations]
		WHERE NAME in ('Max server memory (MB)')

select @maxservermemvalue =  cast(value_in_use as int)
	FROM [master].[sys].[configurations]
		WHERE NAME in ('Max server memory (MB)')


--FIND PERCENTAGE MAX SERVER IS SET IN RELATION TO PHYSICAL MEMEORY 
DECLARE @percentage float

SELECT @percentage= @max / @physical * 100 

/*
--LOGIC CHECK TO SEE IF MAX SERVER MEMORY IS SET TO 80% GIVE OR TAKE A FEW PERCENTAGE POINTS
DECLARE @results varchar(40)
if (@percentage > 79 and @percentage <= 90)
	SELECT @results = 'max memory SET @ 80%..ish' 
	else 
	SELECT @results=  'max memory not SET to correct value' 
*/

DECLARE @server varchar(16)
SET @server = (SELECT CONVERT(VARCHAR(16),SERVERPROPERTY('ServerName')))  -- SERVERNAME

DECLARE @product sql_variant
SET @product = (SELECT SERVERPROPERTY('productversion')) --SQL_Server_Build_Version

DECLARE @ed sql_variant  
SET @ed = (SELECT SERVERPROPERTY ('edition')) --EDITION

DECLARE @level sql_variant 
SET @level = (SELECT SERVERPROPERTY ('productlevel'))  --PATCH LEVEL

DECLARE @servCol sql_variant
SET @servCol = (SELECT SERVERPROPERTY('collation'))  --SERVER COLLATION

declare @optimize sql_variant
set @optimize = (select value_in_use from sys.configurations where name = 'optimize for ad hoc workloads')

declare @maxdop int
set @maxdop = (select cast(value_in_use as int) from sys.configurations
where name = 'max degree of parallelism')

declare @ctp int

select @ctp =  cast(value_in_use as int)   from sys.configurations
where name = 'cost threshold for parallelism'

if object_id('tempdb..#tracestatus') is not null
drop table #tracestatus

if object_id('tempdb..#tflags') is not null
drop table #tflags



create table #tracestatus
(traceflag int, 
status bit, 
global bit, 
sessions bit)

insert into #tracestatus
exec('dbcc tracestatus')

declare @tflags varchar(40)

select substring((select ','+cast(b.traceflag as char(5)) from #tracestatus b where a.global = b.global
	for xml path('')),2,1000) as TraceFlags 
	into #tflags
	from #tracestatus a
where global = 1
group by a.global

select @tflags = traceflags
from #tflags


INSERT into #audit
VALUES
(
@server, 
@product, 
@ed, 
@level, 
@sqlproductlevel,
@servCol,
@maxservermemvalue,
@percentage,	
@optimize,
--@results,
@physical,
@maxdop,
@ctp,
@tflags)


SELECT * FROM #audit

"  -EnableException
##primary audit info

write-host "Getting CPU info...."$($server.servername)

##$CPUs = Get-WmiObject -ComputerName $($server.servername) -class Win32_Processor 
$cores = Get-CimInstance -ComputerName $($server.servername) -class Win32_computersystem | Select-Object numberoflogicalprocessors, model

##insert collections into dbo.servers

$updatequery = "update servers.servers 
set 
SQL_Build_Version ='$($audit.SQl_Server_Build_Version)'
, SQL_Server_Edition = '$($audit.SQL_Server_Edition)'
, SQL_Server_Patch_Level ='$($audit.SQl_Server_PatchLevel)'
, SQL_Server_Product_Level = '$($audit.sql_product_level)'
, Server_Collation = '$($audit.Server_Collation)'
,Max_Server_Memory_value_in_use = $($audit.Max_Server_Value)
,Optimize_for_AD_HOC = '$($audit.Optimize_for_AD_Hoc)'
,Max_Server_percentage = '$($audit.Max_Server_Percentage)'
,Core_count = $($cores.numberoflogicalprocessors)
,RAM = $($audit.RAM) 
,Max_DOP = $($audit.max_dop)
,Trace_flags ='$($audit.tflags)'
,CostThreshold = $($audit.CostThreshold)
,repo_create_date = '$($repodate)'
,ServerModel = '$($cores.model)'
where servers.servers.Servername like '$($server.servername)%' 

"

Invoke-DbaQuery -SqlInstance $repo -database dbstats -query $updatequery  -EnableException

##ifi query


write-host "Getting Version info...."$($server.servername)

##ifi and LPIM query

$LPIMQuery = "SELECT sql_memory_model_desc as LPIM
        FROM sys.dm_os_sys_info;"

$Locked = Invoke-DbaQuery -SqlInstance $($server.servername) -Database Master -query $LPIMQuery

    Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET LPIM = '$($Locked.LPIM)'
                                                                            WHERE Servername = '$($server.servername)'" #-SuppressProviderContextWarning

write-host "Getting DB Components."$($server.servername)

$services =  Get-Service -ComputerName $($server.servername) |?{$_.displayname -like '*SQL*' -and $_.name -notlike '*TELEM*'}

$ssis = $services |?{$_.DisplayName -like '*Integration*' }
$ssas = $services |?{$_.DisplayName -like '*Analysis*' }
$ssrs = $services |?{$_.DisplayName -like '*Reporting*' }
$sql  = $services |?{$_.name -eq 'MSSQLSERVER' }


if($ssis.length -gt 0)
    {
    Write-host "$($server.servername)..SSIS is installed" -foreground red  

    Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET is_ssis = 1 
                                                                            WHERE Servername = '$($server.servername)'" #-SuppressProviderContextWarning
    }

if($ssas.length -gt 0)
    {

Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET is_ssas = 1 
                                                                            WHERE Servername = '$($server.servername)'" #-SuppressProviderContextWarning
    }

if($ssrs.length -gt 0)
    {
Write-host "$($server.servername)..SSRS is installed" -foreground red  

  Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET is_ssrs = 1 
                                                                         WHERE Servername = '$($server.servername)'" #-SuppressProviderContextWarning
    }
 

 $AgentService = Get-DbaService -ComputerName $($server.servername) -Type Agent

   Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET SQLServerAgentAccount = '$($AgentService.StartName)'
                                                                         WHERE Servername = '$($server.servername)'"

 $EngineService = Get-DbaService -ComputerName $($server.servername) -Type Engine

    Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -query "UPDATE Servers.Servers
                                                                            SET SQLServerAccount = '$($EngineService.StartName)'
                                                                         WHERE Servername = '$($server.servername)'"

  }
 catch [Exception] {

    Write-Host -------------  failure for $($server.servername) ----------------  -BackgroundColor blue -ForegroundColor Yellow
    $errormessage = $Error[0].Exception.Message -replace "'", ""  
    write-host $errormessage  -foreground red -BackgroundColor Yellow

   ## Invoke-DbaQuery -SqlInstance $repo -Database DBStats -query  "Insert into  Failure.collection_failure_log (serverid, ErrorMessage, Collection_time, job_name) values ($($server.serverid),'$($errormessage)','$($repodate)','Server Audit')"    

    }  ##Catch Block
}  ##Foreach block 

<#############################################
Pulling data from RDS instances 
##############################################>

Write-Host "Gathering RDS DB metdata" -ForegroundColor Red -BackgroundColor white

$RDSservers = Invoke-DbaQuery -SqlInstance $repo  -Database dbstats -Query "
select serverid, servername
	from servers.servers 
		WHERE decomm = 0 and is_SQL = 1 and is_rds = 1

            
" 
Foreach ($RDS in $RDSservers) 
    {
Try{
     
     Write-Host "Working on $($RDS.Servername)" -ForegroundColor White -BackgroundColor Red

    $RDSaudit = Invoke-DbaQuery -SqlInstance $($RDS.servername) -Database master   -Query "--DROP TEMP TABLE IF ALREADY EXISTS

    if OBJECT_ID('tempdb..#audit')is not null
	    drop table #audit
    go 
    --CREATE TEMP TABLE FOR SERVER AND DB RESULTS
 	
    create table #audit
    (Servername varchar(16)
    ,SQl_Server_Build_Version sql_variant
    ,SQL_Server_Edition sql_variant
    ,SQl_Server_PatchLevel sql_variant
    ,SQL_Product_level sql_variant
    ,Server_Collation sql_variant 
    ,Max_Server_Value Int
    ,Max_Server_Percentage float
    ,Optimize_for_AD_Hoc sql_variant
    ,RAM int
    ,max_dop int
    ,CostThreshold int
    ,tflags varchar(40)
    )

    --DETERMINE COLLATION OF SERVER AND VCLOUD DB

    DECLARE @scol sql_variant
    DECLARE @collation varchar(30)

    SELECT @scol =SERVERPROPERTY('collation') 

    declare @sqlproductlevel sql_variant
    select @sqlproductlevel = SERVERPROPERTY('ProductUpdateLevel')

    --DETERMINE AMOUNT OF PHYSICAL MEMORY BOX

    DECLARE @physical FLOAT;
    DECLARE @max FLOAT;
    DECLARE @maxservermemvalue INT;


    if object_id('tempdb..#phsyicalmem') is not null
    drop table #phsyicalmem

    CREATE TABLE #phsyicalmem
    (mem_value float)

    DECLARE @cmd VARCHAR(200);
    IF NOT EXISTS
    (
        SELECT *
        WHERE CONVERT(VARCHAR(128), SERVERPROPERTY('ProductVersion')) LIKE '9%'  --find max server mem on 2005 box
    )
    BEGIN
    
        SET @cmd
            = 'DECLARE @mem float; 
    SELECT @mem = round(([total_physical_memory_kb] / 1024.0/1024.0),0,0)
	    FROM [master].[sys].[dm_os_sys_memory]
    SELECT @mem ';

    INSERT INTO #phsyicalmem
    (
        mem_value
    )
    EXECUTE (@cmd);

    END;
    ELSE
    BEGIN
        SET @cmd
            = 'DECLARE @mem float;
    SELECT @mem = ROUND((physical_memory_in_bytes/1024.0/1024.0/1024.0),0,0)
    FROM sys.dm_os_sys_info WITH (NOLOCK) OPTION (RECOMPILE)
    Select @mem';
        --PRINT @sql
     --   EXECUTE (@phsyical);
	
    INSERT INTO #phsyicalmem
    (
        mem_value
    )
    EXECUTE (@cmd);
    END;

    SELECT @physical = (SELECT  mem_value FROM #phsyicalmem)

    --CONVERT MEMORY RESULT TO GBs
    SELECT @max = CASE WHEN VALUE_IN_USE = 0 or value_in_use = 2147483647  THEN @physical
				    else cast(value_in_use as float)/1024.0 END
	    FROM [master].[sys].[configurations]
		    WHERE NAME in ('Max server memory (MB)')

    select @maxservermemvalue =  cast(value_in_use as int)
	    FROM [master].[sys].[configurations]
		    WHERE NAME in ('Max server memory (MB)')


    --FIND PERCENTAGE MAX SERVER IS SET IN RELATION TO PHYSICAL MEMEORY 
    DECLARE @percentage float

    SELECT @percentage= @max / @physical * 100 

    /*
    --LOGIC CHECK TO SEE IF MAX SERVER MEMORY IS SET TO 80% GIVE OR TAKE A FEW PERCENTAGE POINTS
    DECLARE @results varchar(40)
    if (@percentage > 79 and @percentage <= 90)
	    SELECT @results = 'max memory SET @ 80%..ish' 
	    else 
	    SELECT @results=  'max memory not SET to correct value' 
    */

    DECLARE @server varchar(16)
    SET @server = (SELECT CONVERT(VARCHAR(16),SERVERPROPERTY('ServerName')))  -- SERVERNAME

    DECLARE @product sql_variant
    SET @product = (SELECT SERVERPROPERTY('productversion')) --SQL_Server_Build_Version

    DECLARE @ed sql_variant  
    SET @ed = (SELECT SERVERPROPERTY ('edition')) --EDITION

    DECLARE @level sql_variant 
    SET @level = (SELECT SERVERPROPERTY ('productlevel'))  --PATCH LEVEL

    DECLARE @servCol sql_variant
    SET @servCol = (SELECT SERVERPROPERTY('collation'))  --SERVER COLLATION

    declare @optimize sql_variant
    set @optimize = (select value_in_use from sys.configurations where name = 'optimize for ad hoc workloads')

    declare @maxdop int
    set @maxdop = (select cast(value_in_use as int) from sys.configurations
    where name = 'max degree of parallelism')

    declare @ctp int

    select @ctp =  cast(value_in_use as int)   from sys.configurations
    where name = 'cost threshold for parallelism'

    if object_id('tempdb..#tracestatus') is not null
    drop table #tracestatus

    if object_id('tempdb..#tflags') is not null
    drop table #tflags



    create table #tracestatus
    (traceflag int, 
    status bit, 
    global bit, 
    sessions bit)

    insert into #tracestatus
    exec('dbcc tracestatus')

    declare @tflags varchar(40)

    select substring((select ','+cast(b.traceflag as char(5)) from #tracestatus b where a.global = b.global
	    for xml path('')),2,1000) as TraceFlags 
	    into #tflags
	    from #tracestatus a
    where global = 1
    group by a.global

    select @tflags = traceflags
    from #tflags


    INSERT into #audit
    VALUES
    (
    @server, 
    @product, 
    @ed, 
    @level, 
    @sqlproductlevel,
    @servCol,
    @maxservermemvalue,
    @percentage,	
    @optimize,
    --@results,
    @physical,
    @maxdop,
    @ctp,
    @tflags)


    SELECT * FROM #audit

    "  -EnableException  

    $CoresQuery = "select count(*) as Cores from sys.dm_os_schedulers
                    where Status = 'VISIBLE ONLINE' "

$Cores = Invoke-DbaQuery -SqlInstance $($RDS.servername) -Database master   -Query $CoresQuery


    $RDSupdatequery = "update servers.servers 
        set 
        SQL_Build_Version ='$($RDSaudit.SQl_Server_Build_Version)'
        , SQL_Server_Edition = '$($RDSaudit.SQL_Server_Edition)'
        , SQL_Server_Patch_Level ='$($RDSaudit.SQl_Server_PatchLevel)'
        , SQL_Server_Product_Level = '$($RDSaudit.sql_product_level)'
        , Server_Collation = '$($RDSaudit.Server_Collation)'
        ,Max_Server_Memory_value_in_use = $($RDSaudit.Max_Server_Value)
        ,Optimize_for_AD_HOC = '$($RDSaudit.Optimize_for_AD_Hoc)'
        ,Max_Server_percentage = '$($RDSaudit.Max_Server_Percentage)'
        ,Core_count = $($Cores.Cores)
        ,RAM = $($RDSaudit.RAM) 
        ,Max_DOP = $($RDSaudit.max_dop)
        ,Trace_flags ='$($RDSaudit.tflags)'
        ,CostThreshold = $($RDSaudit.CostThreshold)
        ,repo_create_date = '$($repodate)'
        --,ServerModel = '$($cores.model)'
        where servers.servers.Servername = '$($RDS.servername)' "


    Write-Host "Updating Repo" -ForegroundColor Red -BackgroundColor white


 Invoke-DbaQuery -SqlInstance $repo -Database DBstats -Query "$($RDSupdatequery)"   


  }
 catch [Exception] {

    Write-Host -------------  failure for $($RDS.servername) ----------------  -BackgroundColor blue -ForegroundColor Yellow
    $errormessage = $Error[0].Exception.Message -replace "'", ""  
    write-host $errormessage  -foreground red -BackgroundColor Yellow

   ## Invoke-DbaQuery -SqlInstance $repo -Database DBStats -query  "Insert into  Failure.collection_failure_log (serverid, ErrorMessage, Collection_time, job_name) values ($($server.serverid),'$($errormessage)','$($repodate)','Server Audit')"    

    }  ##Catch Block
} ##RDSForeach
