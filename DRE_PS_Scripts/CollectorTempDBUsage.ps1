Import-Module DBATools 
##Import-Module AWSPowershell

Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register

$CollectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$SQLInstance = "mongo-mssql-1-production.c6ehn5aqgtrp.us-west-2.rds.amazonaws.com"

$TempLogUsageQuery =
"IF OBJECT_ID('tempdb..#TempForLogSpace') IS NOT NULL
    BEGIN
        DROP TABLE #TempForLogSpace;
    END;

CREATE TABLE #TempForLogSpace
    (
      DataBaseName VARCHAR(100) ,
      LogSizeMB NUMERIC(18, 4) ,
      LogPercentage NUMERIC(18, 4) ,
	  LogSpaceUsedMB as (LogSizeMB *(LogPercentage/100)),
      Status INT
    );

INSERT  INTO #TempForLogSpace(DataBaseName,LogSizeMB,LOgPercentage,Status)
        EXEC ( 'DBCC sqlperf(logspace) WITH NO_INFOMSGS'
            );	

Select * ,'$($CollectionTime)' as Collection_Time 
from #TempForLogSpace
where DataBaseName = 'TempDB'"


$LogUsage = Invoke-DbaQuery -SqlInstance $SQLInstance -Database TempDb -Query $TempLogUsageQuery -as DataSet

$TempDBUsage = get-DbaTempDbUsage -SqlInstance $SQLInstance |?{$_.spid -gt 50}  | Select *, @{Name='CollectionTime'; Expression={$CollectionTime}} 


$LogUsage | Write-DbaDbTableData -SQLInstance localhost -database DBStats -table Collector.TempDBLogUsage -AutoCreateTable 
$TempDBUsage | Write-DbaDbTableData -SQLInstance localhost -database DBStats -table Collector.TempDBUsage -AutoCreateTable 


$DBCCOpenTran = Get-DbaDbDbccOpenTran -SqlInstance $SQLInstance -Database tempdb | Select *,@{Name='CollectionTime'; Expression={$CollectionTime}} 

$DBCCOpenTran | Write-DbaDbTableData -SQLInstance localhost -database DBStats -table Collector.TempDBDBCCOpenTran -AutoCreateTable 

$SpWhoIsActiveQuery = "EXEC sp_WhoIsActive 
    @output_column_list = '[database_name][dd hh:mm:ss.mss][session_id][block%][tempdb_allocations][login_name][host_name][program_name][login_time][start_time][sql_text][sql_command][wait_info][used_memory][granted_memory][query_plan][status][open_tran_count]',
  @get_outer_command = 1"

$SPWhoIsActive = Invoke-DbaQuery -SqlInstance $SqlInstance -Database DBA -Query $SpWhoIsActiveQuery | Select *,@{Name='CollectionTime'; Expression={$CollectionTime}} 

$SPWhoIsActive | Write-DbaDbTableData -SQLInstance localhost -database DBStats -table Collector.SPWhoIsActive_Command_TranCount -AutoCreateTable 



$OpenTranInputBufferQuery = "Use TempDB 
go 


Drop Table if Exists #OpenTran;
Drop Table if Exists #OpenTranResults;
Drop Table if Exists #InputBuffer;
Drop Table if Exists #TempDBOpenTranInputBuffer;

--Capture OpenTran data
CREATE TABLE #OpenTran (
    Field VARCHAR(255),
    Value VARCHAR(255)
);

INSERT INTO #OpenTran
EXEC('DBCC OPENTRAN WITH TABLERESULTS');

--Pivot that data for easier consumption
SELECT *
into #OpenTranResults
FROM (
    SELECT Field, Value
    FROM #OpenTran
) AS SourceTable
PIVOT (
    MAX(Value)
    FOR Field IN ([OLDACT_SPID], [OLDACT_UID], [OLDACT_NAME], [OLDACT_RECOVERYUNITID], [OLDACT_LSN], [OLDACT_STARTTIME], [OLDACT_SID])
) AS PivotTable


--get the spid from OpenTran and run through the InputBuffer
Declare @spid int
Set @spid = (SELECT OldAct_SPID FROM #OpenTranResults)

Declare @cmd varchar(100)
Set @cmd =  'dbcc inputbuffer('+cast(@spid as varchar(6))+')'

Create Table #InputBuffer
(EventType varchar(100),
[Parameters] varchar(100),
Eventinfo varchar(max))

INSERT INTO #InputBuffer
Execute (@cmd) 

--Select * from #InputBuffer
--Select * from #OpenTranResults

--Create a table for all info from OpenTran and the InputBuffer

Create Table #TempDBOpenTranInputBuffer
([OLDACT_SPID] int, 
[OLDACT_UID] varchar(200), 
[OLDACT_NAME] varchar(200), 
[OLDACT_RECOVERYUNITID] varchar(200), 
[OLDACT_LSN] varchar(200), 
[OLDACT_STARTTIME] datetime2, 
[OLDACT_SID] varchar(max),
[EventType] varchar(200),
[Parameters] varchar(200),
[EventInfo] varchar(max))

Insert into #TempDBOpenTranInputBuffer([OLDACT_SPID], [OLDACT_UID], [OLDACT_NAME], [OLDACT_RECOVERYUNITID], [OLDACT_LSN], [OLDACT_STARTTIME], [OLDACT_SID])
Select * from #OpenTranResults

--Update the table with the InputBuffer data
Update #TempDBOpenTranInputBuffer
Set EventType = i.EventType, [Parameters] = i.[Parameters], EventInfo = i.Eventinfo
from #InputBuffer i


Select * from #TempDBOpenTranInputBuffer
"

$OpenTranInputBuffer = Invoke-DbaQuery -SqlInstance $SQLInstance -Database TempDB -Query $OpenTranInputBufferQuery |  Select *,@{Name='CollectionTime'; Expression={$CollectionTime}} 


$OpenTranInputBuffer | Write-DbaDbTableData -SQLInstance localhost -database DBStats -table Collector.OpenTranInputBuffer -AutoCreateTable 

