DECLARE @SPID INT = 59;

;WITH agg AS
(
     SELECT qp.[session_id],
			SUM(qp.[row_count]) AS [RowsProcessed],
            SUM(qp.[estimate_row_count]) AS [TotalRows],
            MAX(qp.last_active_time) - MIN(qp.first_active_time) AS [ElapsedMS],
            MAX(IIF(qp.[close_time] = 0 AND qp.[first_row_time] > 0,
                    [physical_operator_name],
                    N'<Transition>')) AS [CurrentStep]
     FROM sys.dm_exec_query_profiles qp
     WHERE qp.[physical_operator_name] IN (N'Table Scan', N'Clustered Index Scan',
                                           N'Index Scan',  N'Sort')
     AND   qp.[session_id] = @SPID
	 Group by qp.[session_id]
), comp AS

(
     SELECT *,
            ([TotalRows] - [RowsProcessed]) AS [RowsLeft],
            ([ElapsedMS] / 1000.0) AS [ElapsedSeconds]
     FROM   agg
)
SELECT [session_id],
	   [CurrentStep],
       [TotalRows],
       [RowsProcessed],
       [RowsLeft],
       CONVERT(DECIMAL(5, 2),
               (([RowsProcessed] * 1.0) / [TotalRows]) * 100) AS [PercentComplete],
       [ElapsedSeconds],
       (([ElapsedSeconds] / [RowsProcessed]) * [RowsLeft]) AS [EstimatedSecondsLeft],
       DATEADD(SECOND,
               (([ElapsedSeconds] / [RowsProcessed]) * [RowsLeft]),
               GETDATE()) AS [EstimatedCompletionTime]
FROM   comp;

/**************************************
**************************************
**************************************
**************************************

 select * 
 from dba.dbo.CommandLog	
	where CommandType like '%Index%'
 order by endtime desc

Select	percent_complete, 
		DATEADD(ss,estimated_completion_time/1000,getdate()) AS estimated_completion_time ,
		datediff(MINUTE, getdate(), DATEADD(ss,estimated_completion_time/1000,getdate())) as MinutesTillComplete
from sys.dm_exec_requests 
	where command like '%dbcc%'

**************************************
**************************************
***************************************/

SELECT
    r.session_id,
	    SUBSTRING(
        st.text,
        r.statement_start_offset / 2,
        CASE 
            WHEN r.statement_end_offset = -1 THEN LEN(st.text) * 2
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2
        END
    ) AS running_statement,
    r.status,
    r.start_time,
    r.command,
    r.cpu_time,
	r.reads,
    r.writes,
    r.logical_reads,
    r.wait_type,
    r.wait_time,
    r.last_wait_type,
    r.wait_resource,
    r.blocking_session_id
FROM sys.dm_exec_requests r
	CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
WHERE r.session_id = @spid