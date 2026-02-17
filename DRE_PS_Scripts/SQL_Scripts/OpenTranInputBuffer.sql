Use TempDB 
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



