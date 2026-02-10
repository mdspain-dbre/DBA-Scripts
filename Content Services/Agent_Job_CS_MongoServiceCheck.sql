/*
===============================================================================
SQL AGENT JOB: CS_MongoServiceCheck
===============================================================================
Purpose:    Executes CS_MongoServiceCheck.ps1 to monitor MongoDB Windows 
            service status and send Slack alerts if services are not running.

Schedule:   Every 15 minutes, 24/7

Script:     D:\DRE_PS_Scripts\CS_MongoServiceCheck.ps1

Author:     Michael DSpain
Created:    February 2026
===============================================================================
*/

USE [msdb]
GO

/****** Object:  Job [CS_MongoServiceCheck]    Script Date: 2/10/2026 ******/
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

/****** Object:  JobCategory [ContentServices]    Script Date: 2/10/2026 ******/
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'ContentServices' AND category_class=1)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'ContentServices'
    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
END

DECLARE @jobId BINARY(16)

-- Create the job
EXEC @ReturnCode = msdb.dbo.sp_add_job 
    @job_name=N'CS_MongoServiceCheck', 
    @enabled=1, 
    @notify_level_eventlog=0, 
    @notify_level_email=0, 
    @notify_level_netsend=0, 
    @notify_level_page=0, 
    @delete_level=0, 
    @description=N'Monitors MongoDB Windows service status across production servers. Sends Slack alert to cpie-dre-alerts if any services are not running.', 
    @category_name=N'ContentServices', 
    @owner_login_name=N'sa', 
    @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

/****** Object:  Step [Execute MongoDB Service Check]    Script Date: 2/10/2026 ******/
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
    @job_id=@jobId, 
    @step_name=N'Execute MongoDB Service Check', 
    @step_id=1, 
    @cmdexec_success_code=0, 
    @on_success_action=1,           -- Quit with success
    @on_success_step_id=0, 
    @on_fail_action=2,              -- Quit with failure
    @on_fail_step_id=0, 
    @retry_attempts=0, 
    @retry_interval=0, 
    @os_run_priority=0, 
    @subsystem=N'CmdExec', 
    @command=N'powershell.exe -ExecutionPolicy Bypass -File "D:\DRE_PS_Scripts\CS_MongoServiceCheck.ps1"', 
    @flags=0, 
    @proxy_name=N'PS_Connect'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Set the starting step
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

/****** Object:  Schedule [Every 15 Minutes]    Script Date: 2/10/2026 ******/
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule 
    @job_id=@jobId, 
    @name=N'Every 1 Minutes', 
    @enabled=1, 
    @freq_type=4,                   -- Daily
    @freq_interval=1,               -- Every 1 day
    @freq_subday_type=4,            -- Minutes
    @freq_subday_interval=1,       -- Every 15 minutes
    @freq_relative_interval=0, 
    @freq_recurrence_factor=0, 
    @active_start_date=20260210,    -- Start date: Feb 10, 2026
    @active_end_date=99991231,      -- No end date
    @active_start_time=0,           -- Start at midnight (00:00:00)
    @active_end_time=235959         -- End at 23:59:59
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Add the job to the local server
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION

EndSave:
GO
