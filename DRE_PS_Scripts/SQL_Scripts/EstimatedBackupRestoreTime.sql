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