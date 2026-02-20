Drop Table if Exists #OpenTranPivot;
Drop Table if Exists #OpenTranPivotFinal;

SELECT *
Into #OpenTranPivot
FROM (
    SELECT Field, Data, CollectionTime
    FROM [Collector].[TempDBDBCCOpenTran]
	where CollectionTime > getdate() -2
) AS SourceTable
PIVOT (
    MAX(Data)
    FOR Field IN ([OLDACT_SPID], [OLDACT_UID], [OLDACT_NAME], [OLDACT_RECOVERYUNITID], [OLDACT_LSN], [OLDACT_STARTTIME], [OLDACT_SID])
) AS PivotTable
Order by CollectionTime


Select *, DATEDIFF(second,OLDACT_STARTTIME,CollectionTime) as TranLengthSeconds
into #OpenTranPivotFinal
from #OpenTranPivot
Order by TranLengthSeconds desc 

/*****************************************
TempDB Usage
*****************************************/

Select * 
from [Collector].[TempDBUsage]
where CollectionTime = (select Top(1) CollectionTime from #OpenTranPivotFinal Order by TranLengthSeconds desc)
--and Spid = (select Top(1) OLDACT_SPID from #OpenTranPivotFinal Order by TranLengthSeconds desc)
order by TotalUserAllocatedKB desc 

/*****************************************
TempDB Log Usage 
*****************************************/


select *,format(LogSizeMB/1024.0,'N0')as Formatted_LogSizeGB,format(LogSpaceUsedMB/1024.0,'N0')as Formatted_LogSpaceUsedGB 
from [Collector].TempDBLogUsage
where Collection_Time = (select Top(1) CollectionTime from #OpenTranPivotFinal Order by TranLengthSeconds desc)
order by Collection_Time desc

/*****************************************
Longest OpenTran
*****************************************/

Select top(1)*,TranLengthSeconds/60.0 as TranLengthMinutes
from #OpenTranPivotFinal
Order by TranLengthSeconds desc 

/*****************************************
SP_WhoIsActive
*****************************************/

Select * 
from Collector.SPWhoIsActive_Command_TranCount
where  CollectionTime = (select Top(1) CollectionTime from #OpenTranPivotFinal Order by TranLengthSeconds desc)
order by [session_id]




/*
 SELECT		t.[StringId], 
			t.[Fingerprint], 
			t.[Value]      
 FROM          (              SELECT                  
								r.[StringId], 
								r.[Fingerprint],                  
								r.[Value], 
								(ROW_NUMBER() OVER(PARTITION BY r.[Fingerprint], r.[Value] ORDER BY r.[StringId])) AS [Rank]              
								FROM                  @results r          ) t      
WHERE          t.[Rank] = 1  

*/


/*
 select *,format(LogSizeMB,'N0') as Formatted_LogSizeMB ,format(LogSpaceUsedMB,'N0') as Formated_LogSpaceUsedMB
  from [Collector].[TempDBLogUsage]
where Collection_Time = (select Top(1) CollectionTime from #OpenTranPivotFinal Order by TranLengthSeconds desc)
*/



