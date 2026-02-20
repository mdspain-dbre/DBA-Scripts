/*
--------------------------------------------------------------------------------- 
--Database Backups for all databases For Previous Week 
--------------------------------------------------------------------------------- 
SELECT 
   CONVERT(CHAR(100), SERVERPROPERTY('Servername')) AS Server, 
   msdb.dbo.backupset.database_name, 
   msdb.dbo.backupset.backup_start_date, 
   msdb.dbo.backupset.backup_finish_date, 
   msdb.dbo.backupset.expiration_date,
   device_type,
   CASE msdb..backupset.type 
      WHEN 'D' THEN 'Database' 
      WHEN 'L' THEN 'Log' 
      END AS backup_type, 
   msdb.dbo.backupset.backup_size, 
   msdb.dbo.backupmediafamily.logical_device_name, 
   msdb.dbo.backupmediafamily.physical_device_name, 
   msdb.dbo.backupset.name AS backupset_name, 
   msdb.dbo.backupset.description 
FROM 
   msdb.dbo.backupmediafamily 
   INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id 
WHERE 
   --(CONVERT(datetime, msdb.dbo.backupset.backup_start_date, 102) >= GETDATE() - 180) and
   msdb..backupset.type  = 'D'
ORDER BY 
   msdb.dbo.backupset.database_name, 
   msdb.dbo.backupset.backup_finish_date 


*/

/****** Object:  StoredProcedure [dba].[SqlNativeBackup]    Script Date: 9/26/2025 11:57:31 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

USE DBA 
go 

CREATE or Alter PROCEDURE [dbo].[SqlNativeBackup] @print bit = 1

as

--Params to be formated in proc
--DECLARE @BackupType VARCHAR(10) = 'Full'
--DECLARE @dbName NVARCHAR(100) = 'IMS-dev'
--DECLARE  @All INT = 1

DECLARE @path VARCHAR(500) = 'arn:aws:s3:::prod-sql-1-backups/FULL/'
DECLARE @name VARCHAR(500)
DECLARE @Stripedfilename VARCHAR(256)
DECLARE @date NVARCHAR(100) = (SELECT FORMAT(GETDATE(), 'dd-MM-yyyy-hhmm'))
DECLARE @stripes int

--------------------------------------------
----Feed Cursor with params / No Print
--------------------------------------------

IF @print = 0

BEGIN


DECLARE db_cursor CURSOR FOR  
  SELECT name
  FROM sys.databases 
where database_id > 4 and name <> 'rdsadmin'


OPEN db_cursor   
FETCH NEXT FROM db_cursor INTO @name

WHILE @@FETCH_STATUS = 0   
BEGIN

SET @Stripedfilename = @path + @name +'/' + @name + '_' + @date  +'*' --+ '.bak'  
SET @stripes=  8

  BEGIN
	Print 'running  backups for '+@name+' to '+@StripedFileName
    EXEC msdb.dbo.rds_backup_database 
    @source_db_name=@name,
    @s3_arn_to_backup_to=@Stripedfilename, 
    @type ='FULL',
    @overwrite_S3_backup_file=1,
    @number_of_files=@stripes;
  END


FETCH NEXT FROM db_cursor INTO @name 
END

CLOSE db_cursor   
DEALLOCATE db_cursor

END


--------------------------------------------
----Print only
--------------------------------------------

If @print = 1

BEGIN

DECLARE db_cursor CURSOR FOR  
  SELECT name
  FROM sys.databases 
where database_id > 4 and name <> 'rdsadmin'

OPEN db_cursor   
FETCH NEXT FROM db_cursor INTO @name

WHILE @@FETCH_STATUS = 0   
BEGIN


SET @Stripedfilename = @path + @name +'/' + @name + '_' + @date  +'*' --+ '.bak'  
SET @stripes =  8

BEGIN
DECLARE @sql NVARCHAR(MAX)
SET @sql = 'EXEC msdb.dbo.rds_backup_database
@source_db_name=' + QUOTENAME(@name, '''') + ',
@s3_arn_to_backup_to=' + QUOTENAME(@Stripedfilename, '''') + ',
@type=''FULL'',
@overwrite_S3_backup_file=1,
@number_of_files='+CONVERT(NVARCHAR(10),@stripes)+';'
PRINT @sql 

END

FETCH NEXT FROM db_cursor INTO @name

END


CLOSE db_cursor   
DEALLOCATE db_cursor

END
GO


/*
select TOP 10* from msdb.dbo.rds_fn_task_status(null,0)
where created_at >= '2025-10-05 20:39:30.780'
ORDER BY task_id DESC
--@number_of_files=8;

 [2025-10-06 02:47:38.623] Task execution has started. [2025-10-06 02:47:38.630] BACKUP_DB task will initiate a multi-file task with 8 file(s). 
 The files are: FULL/Harmony/Harmony_06-10-2025-0200_1-of-8, FULL/Harmony/Harmony_06-10-2025-0200_2-of-8, FULL/Harmony/Harmony_06-10-2025-0200_3-of-8, FULL/Harmony/Harmony_06-10-2025-0200_4-of-8, FULL/Harmony/Harmony_06-10-2025-0200_5-of-8, FULL/Harmony/Harmony_06-10-2025-0200_6-of-8, FULL/Harmony/Harmony_06-10-2025-0200_7-of-8, FULL/Harmony/Harmony_06-10-2025-0200_8-of-8. [2025-10-06 03:05:41.697] Aborting native backup because there is an RDS automated backup in progress. [2025-10-06 03:05:41.823] Write on "ABAC134A-14B8-43C5-AC05-4E9C7703613E" failed: 995(The I/O operation has been aborted because of either a thread exit or an application request.)  A nonrecoverable I/O error occurred on file "ABAC134A-14B8-43C5-AC05-4E9C7703613E:" 995(The I/O operation has been aborted because of either a thread exit or an application request.).  BACKUP DATABASE is terminating abnormally. [2025-10-06 03:05:42.713] Aborted the task because of a task failure or an overlap with your preferred backup window for RDS automated backup. [2025-10-06 03:05:42.723] FULL/Harmony/Harmony_06-10-2025-0200_1-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:45.573] FULL/Harmony/Harmony_06-10-2025-0200_1-of-8: S3 processing has been aborted [2025-10-06 03:05:45.583] FULL/Harmony/Harmony_06-10-2025-0200_2-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:47.127] FULL/Harmony/Harmony_06-10-2025-0200_2-of-8: S3 processing has been aborted [2025-10-06 03:05:47.137] FULL/Harmony/Harmony_06-10-2025-0200_3-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:48.220] FULL/Harmony/Harmony_06-10-2025-0200_3-of-8: S3 processing has been aborted [2025-10-06 03:05:48.230] FULL/Harmony/Harmony_06-10-2025-0200_4-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:48.333] FULL/Harmony/Harmony_06-10-2025-0200_4-of-8: S3 processing has been aborted [2025-10-06 03:05:48.343] FULL/Harmony/Harmony_06-10-2025-0200_5-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:48.447] FULL/Harmony/Harmony_06-10-2025-0200_5-of-8: S3 processing has been aborted [2025-10-06 03:05:48.453] FULL/Harmony/Harmony_06-10-2025-0200_6-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:49.380] FULL/Harmony/Harmony_06-10-2025-0200_6-of-8: S3 processing has been aborted [2025-10-06 03:05:49.390] FULL/Harmony/Harmony_06-10-2025-0200_7-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:49.493] FULL/Harmony/Harmony_06-10-2025-0200_7-of-8: S3 processing has been aborted [2025-10-06 03:05:49.503] FULL/Harmony/Harmony_06-10-2025-0200_8-of-8: Aborting S3 upload, waiting for S3 workers to clean up and exit [2025-10-06 03:05:49.597] FULL/Harmony/Harmony_06-10-2025-0200_8-of-8: 
 S3 processing has been aborted [2025-10-06 03:05:49.610] Task has been aborted



Exec [dbo].[SqlNativeBackup] @print = 1

*/




 