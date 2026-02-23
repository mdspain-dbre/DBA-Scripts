-- Estimated backup/restore completion time
SELECT 
    r.session_id,
    r.command,
    DB_NAME(r.database_id) AS database_name,
    r.percent_complete,
    r.start_time,
    DATEADD(MILLISECOND, r.estimated_completion_time, GETDATE()) AS estimated_completion_time,
    CONVERT(VARCHAR(20), DATEADD(MILLISECOND, r.estimated_completion_time, 0), 108) AS time_remaining,
    r.total_elapsed_time / 1000 / 60 AS elapsed_minutes
FROM sys.dm_exec_requests r
WHERE r.command IN ('BACKUP DATABASE', 'BACKUP LOG', 'RESTORE DATABASE', 'RESTORE LOG', 
                    'RESTORE HEADERONLY', 'RESTORE FILELISTONLY', 'RESTORE VERIFYONLY')
ORDER BY r.start_time;


-- Delete backup history older than a specific date
EXEC msdb.dbo.rds_delete_from_filesystem @file_type = 'ALL';

-- Delete backup/restore task history older than specified days (default 7 days)
EXEC msdb.dbo.rds_task_status @db_name = NULL;  -- View current tasks first

-- Clean up msdb backup history (standard SQL Server, works on RDS)
DECLARE @oldest_date DATETIME = DATEADD(DAY, -30, GETDATE());
EXEC msdb.dbo.sp_delete_backuphistory @oldest_date;

-- Delete specific task from RDS task history
EXEC msdb.dbo.rds_cancel_task @task_id = 123;  -- Only for in-progress tasks