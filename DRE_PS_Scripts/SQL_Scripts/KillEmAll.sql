DECLARE @user_spid int
DECLARE CurSPID CURSOR FAST_FORWARD
FOR
SELECT session_id as 'SPID'
FROM sys.dm_exec_sessions
WHERE is_user_process = 1 and session_id <> @@SPID; 
OPEN CurSPID
FETCH NEXT FROM CurSPID INTO @user_spid
WHILE (@@FETCH_STATUS=0)
	BEGIN
		PRINT 'Killing '+CONVERT(VARCHAR,@user_spid)
		EXEC('KILL '+@user_spid)
FETCH NEXT FROM CurSPID INTO @user_spid
	END
CLOSE CurSPID
DEALLOCATE CurSPID
GO
