Use DBA 
go 
/***************************************
****************************************
high level overview of instance 
****************************************
***************************************/
exec sp_blitzfirst
  
exec sp_blitzwho
  
/***************************************
****************************************
SP_BlitzCache queries to find top consuming queries
****************************************
***************************************/
  
--Find top 10 CPU consuming queries
exec sp_blitzcache @top = 10, @ignoresystemdbs = 1, @sortOrder = 'CPU', @hidesummary = 1, @databasename = 'Harmony'
--find top 10 Read consuming queries
exec sp_blitzcache @top = 10, @ignoresystemdbs = 1, @sortOrder = 'Reads', @hidesummary = 1, @databasename = 'Harmony'
--find top 10 largest Memory Grants
exec sp_blitzcache @top = 10, @ignoresystemdbs = 1, @sortOrder = 'Memory Grant', @hidesummary = 1, @databasename = 'Harmony'
--find top 10 most executed queries
exec sp_blitzcache @top = 10, @ignoresystemdbs = 1, @sortOrder = 'XPM', @hidesummary = 1, @databasename = 'Harmony'

sp_pressuredetector 




EXEC dbo.sp_QuickieStore @database_name = 'Harmony'

/***************************************
****************************************
sp_whoisactive examples
  
https://www.sqlshack.com/an-overview-of-the-sp_whoisactive-stored-procedure/
  
****************************************
***************************************/
  
Exec sp_whoisactive --@get_outer_command = 1

select getdate()
  
/***************************************
****************************************
find lead blocker
****************************************
***************************************/
  
EXEC sp_WhoIsActive
    @find_block_leaders = 1,
    @sort_order = '[blocked_session_count] DESC'
  
/***************************************
****************************************
sp_whoisactive delta queries 
    help determine how much of a resouce a session is taking
    Delta_interval value 5 indicates 5 seconds
    http://whoisactive.com/docs/26_delta/
****************************************
***************************************/
  
EXEC sp_WhoIsActive
    @delta_interval = 5,
	@sort_order = '[reads_delta] DESC'
  
EXEC sp_WhoIsActive
    @delta_interval = 5,
	@sort_order = '[CPU_delta] DESC'

/*
SQL Server Memory 
System Memory State should be "Available physical memory is high"
Buffer Pool
*/


SELECT 
   SERVERPROPERTY('SERVERNAME') AS 'Instance',
   (SELECT cast(value_in_use as int)/1024.0 FROM sys.configurations WHERE name like '%max server memory%') AS 'Max Server Memory GB',
   (SELECT physical_memory_in_use_kb/1024.0/1024 FROM sys.dm_os_process_memory) AS 'SQL Server Memory Usage (GB)',
   (SELECT total_physical_memory_kb/1024.0/1024 FROM sys.dm_os_sys_memory) AS 'Physical Memory (GB)',
   (SELECT available_physical_memory_kb/1024.0/1024 FROM sys.dm_os_sys_memory) AS 'Available Memory (GB)',
   (SELECT system_memory_state_desc FROM sys.dm_os_sys_memory) AS 'System Memory State',
   (SELECT ((total_physical_memory_kb - available_physical_memory_kb)*1.0/total_physical_memory_kb*1.00 )*100.00  FROM sys.dm_os_sys_memory) as Mem_Consumed_Percentage,
   (SELECT [cntr_value] FROM sys.dm_os_performance_counters WHERE [object_name] LIKE '%Manager%' AND [counter_name] = 'Page life expectancy') AS 'Page Life Expectancy',
   GETDATE() AS 'Data Sample Timestamp'


/*
CPU going back in time about 4 hours
*/


DECLARE @ts_now bigint = (SELECT cpu_ticks/(cpu_ticks/ms_ticks) FROM sys.dm_os_sys_info WITH (NOLOCK)); 


SELECT TOP(256) SQLProcessUtilization AS [SQL Server Process CPU Utilization], 
               SystemIdle AS [System Idle Process], 
               100 - SystemIdle - SQLProcessUtilization AS [Other Process CPU Utilization], 
               DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS [Event Time] 
FROM (SELECT record.value('(./Record/@id)[1]', 'int') AS record_id, 
			record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') 
			AS [SystemIdle], 
			record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') 
			AS [SQLProcessUtilization], [timestamp] 
	  FROM (SELECT [timestamp], CONVERT(xml, record) AS [record] 
			FROM sys.dm_os_ring_buffers WITH (NOLOCK)
			WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
			AND record LIKE N'%<SystemHealth>%') AS x) AS y 
ORDER BY record_id DESC OPTION (RECOMPILE);


/*
Top Wait Types 
Please check URL in results set to better under that specific wait type


1.	RESOURCE_SEMAPHORE
2.	CXPACKET
3.	PAGEIOLATCH_EX (there a several different types of this wait..example PAGEIOLATCH_SH, PAGEIOLATCH_UP)
4.	HADR_SYNCH_COMMIT
5.	THREADPOOL
6.	WRITELOG
7.	ASYNC_NETWORK_IO
8.	PAGELATCH_EX (there a several different types of this wait..example PAGELATCH_SH, PAGELATCH_UP)
9.	RESOURCE_SEMAPHORE_QUERY_COMPILE
10.	SOS_SCHEDULER_YIELD  -- https://www.sqlshack.com/how-to-handle-excessive-sos_scheduler_yield-wait-type-values-in-sql-server/


*/
;WITH [Waits] 
AS (SELECT wait_type, wait_time_ms/ 1000.0 AS [WaitS],
          (wait_time_ms - signal_wait_time_ms) / 1000.0 AS [ResourceS],
           signal_wait_time_ms / 1000.0 AS [SignalS],
           waiting_tasks_count AS [WaitCount],
           100.0 *  wait_time_ms / SUM (wait_time_ms) OVER() AS [Percentage],
           ROW_NUMBER() OVER(ORDER BY wait_time_ms DESC) AS [RowNum]
    FROM sys.dm_os_wait_stats WITH (NOLOCK)
    WHERE [wait_type] NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
		N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
		N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT', 
		N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', 
		N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
		N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',
		N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
		N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
		N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',
		N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
		N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',
		N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',
		N'PREEMPTIVE_OS_WRITEFILE',
		N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',
		N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',
		N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
		N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
		N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH',
		N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
		N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SP_SERVER_DIAGNOSTICS_SLEEP',
		N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
		N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
		N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY',
		N'XE_BUFFERMGR_ALLPROCESSED_EVENT', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT','SOS_WORK_DISPATCHER','UCS_SESSION_REGISTRATION',
		'HADR_BACKUP_BULK_LOCK','HADR_AG_MUTEX','HADR_BACKUP_QUEUE','HADR_DB_COMMAND','HADR_TRANSPORT_SESSION','HADR_REPLICAINFO_SYNC',
		'HADR_REPLICAINFO_SYNC','PWAIT_HADR_ACTION_COMPLETED','HADR_RECOVERY_WAIT_FOR_CONNECTION','WAIT_ON_SYNC_STATISTICS_REFRESH','PREEMPTIVE_OS_CLOSEHANDLE',
		'PREEMPTIVE_OS_DELETESECURITYCONTEXT','PREEMPTIVE_OS_QUERYCONTEXTATTRIBUTES','PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICYFREE','PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICY',
		'PREEMPTIVE_OS_REVERTTOSELF','PREEMPTIVE_OS_AUTHORIZATIONOPS','PREEMPTIVE_OS_REPORTEVENT','PREEMPTIVE_OS_CRYPTACQUIRECONTEXT','REDO_THREAD_PENDING_WORK')
    AND waiting_tasks_count > 0)
SELECT
    MAX (W1.wait_type) AS [WaitType],
	CAST (MAX (W1.Percentage) AS DECIMAL (5,2)) AS [Wait Percentage],
	CAST ((MAX (W1.WaitS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgWait_Sec],
    CAST ((MAX (W1.ResourceS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgRes_Sec],
    CAST ((MAX (W1.SignalS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgSig_Sec], 
    CAST (MAX (W1.WaitS) AS DECIMAL (16,2)) AS [Wait_Sec],
    CAST (MAX (W1.ResourceS) AS DECIMAL (16,2)) AS [Resource_Sec],
    CAST (MAX (W1.SignalS) AS DECIMAL (16,2)) AS [Signal_Sec],
    MAX (W1.WaitCount) AS [Wait Count],
	CAST (N'https://www.sqlskills.com/help/waits/' + W1.wait_type AS XML) AS [Help/Info URL]
FROM Waits AS W1
INNER JOIN Waits AS W2
ON W2.RowNum <= W1.RowNum
GROUP BY W1.RowNum, W1.wait_type
HAVING SUM (W2.Percentage) - MAX (W1.Percentage) < 100 -- percentage threshold
OPTION (RECOMPILE);




/*
Be sure TempDB data file are the same size 
*/


select db_name(database_id) as DBName, physical_name, (size*8)/1024.0/1024.0 as SizeGB 
from sys.master_files
where database_id = 2 and type_desc = 'rows'




SELECT  *
 FROM sys.dm_os_waiting_tasks
where resource_description like '2:%'




-- Signal Waits for instance  
-- If signal waits are higher than resource waits that indicates CPU pressure
SELECT CAST(100.0 * SUM(signal_wait_time_ms) / SUM (wait_time_ms) AS NUMERIC(20,2))
AS [Percent_Signal (cpu) waits],
CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM (wait_time_ms) AS NUMERIC(20,2))
AS [Percent_resource waits] FROM sys.dm_os_wait_stats OPTION (RECOMPILE);




--check these values 
--  Max Server Mem should be set to about 85% of total memory
--  Cost Threshold should be set to at least 75
--  Max DOP should be set to 8
Select * from sys.configurations
where name in ('max server memory (MB)','cost threshold for parallelism','max degree of parallelism')




--check these values.  
-- Page verify should be CheckSum
-- delayed durability should be forced
SELECT name as databaseName, page_verify_option_desc, delayed_durability_desc
FROM sys.databases;




-- Drive level latency information
-- Shows you the drive-level latency for reads and writes, in milliseconds
-- Latency above 30-40ms is usually a problem
-- These latency numbers include all file activity against all SQL Server 
-- database files on each drive since SQL Server was last started
SELECT tab.[Drive], tab.volume_mount_point AS [Volume Mount Point], 
	CASE 
		WHEN num_of_reads = 0 THEN 0 
		ELSE (io_stall_read_ms/num_of_reads) 
	END AS [Read Latency],
	CASE 
		WHEN num_of_writes = 0 THEN 0 
		ELSE (io_stall_write_ms/num_of_writes) 
	END AS [Write Latency],
	CASE 
		WHEN (num_of_reads = 0 AND num_of_writes = 0) THEN 0 
		ELSE (io_stall/(num_of_reads + num_of_writes)) 
	END AS [Overall Latency],
	CASE 
		WHEN num_of_reads = 0 THEN 0 
		ELSE (num_of_bytes_read/num_of_reads) 
	END AS [Avg Bytes/Read],
	CASE 
		WHEN num_of_writes = 0 THEN 0 
		ELSE (num_of_bytes_written/num_of_writes) 
	END AS [Avg Bytes/Write],
	CASE 
		WHEN (num_of_reads = 0 AND num_of_writes = 0) THEN 0 
		ELSE ((num_of_bytes_read + num_of_bytes_written)/(num_of_reads + num_of_writes)) 
	END AS [Avg Bytes/Transfer]
FROM (SELECT LEFT(UPPER(mf.physical_name), 2) AS Drive, SUM(num_of_reads) AS num_of_reads,
	         SUM(io_stall_read_ms) AS io_stall_read_ms, SUM(num_of_writes) AS num_of_writes,
	         SUM(io_stall_write_ms) AS io_stall_write_ms, SUM(num_of_bytes_read) AS num_of_bytes_read,
	         SUM(num_of_bytes_written) AS num_of_bytes_written, SUM(io_stall) AS io_stall, vs.volume_mount_point 
      FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
      INNER JOIN sys.master_files AS mf WITH (NOLOCK)
      ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
	  CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) AS vs 
      GROUP BY LEFT(UPPER(mf.physical_name), 2), vs.volume_mount_point) AS tab
ORDER BY [Overall Latency] OPTION (RECOMPILE);




--Find last startup time of SQL


SELECT	ServiceName, 
		Startup_Type_Desc, 
		Status_Desc, 
		Last_StartUp_Time, 
		Service_Account, 
		Is_Clustered, 
		Cluster_NodeName, 
		FileName as BinaryLocation, 
		Instant_File_Initialization_Enabled -- New in SQL Server 2016 SP1
FROM sys.dm_server_services WITH (NOLOCK) OPTION (RECOMPILE);


/*****************************************************
Last Backup
*****************************************************/


;with backup_cte as
(
    select
        database_name,
        backup_type =
            case type
                when 'D' then 'database'
                when 'L' then 'log'
                when 'I' then 'differential'
                else 'other'
            end,
        backup_finish_date,
        rownum = 
            row_number() over
            (
                partition by database_name, type 
                order by backup_finish_date desc
            )
    from msdb.dbo.backupset
)
select
    database_name,
    backup_type,
    backup_finish_date
from backup_cte
where rownum = 1
order by database_name;


--breakdown of db size 
SELECT 
    DB_NAME(database_id) AS DatabaseName,
    CONVERT(DECIMAL(10,2), SUM(size * 8.0 / 1024/1024.0)) AS SizeGB,
	CONVERT(DECIMAL(20,6), SUM(size * 8.0 / 1024/1024.0/1024.0)) AS SizeTB,
	SUM(size * 8.0 / 1024/1024.0/1024.0))
FROM 
    sys.master_files
GROUP BY 
    database_id


--total size of DBs on instance  
--tempdb can vary use database_files against tempdb 
select 	--db_name(database_id) ,
SUM(size * 8.0 / 1024/1024.0)
from 
sys.master_files
--group by database_id

use tempdb 
go 

select 'TempDB',
SUM(size * 8.0 / 1024/1024.0/1024.0)
from sys.database_files