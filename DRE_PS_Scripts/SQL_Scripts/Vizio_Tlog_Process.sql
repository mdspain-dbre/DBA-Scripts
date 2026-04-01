SET NOCOUNT ON;

-- Get latest log backup location (returns NULL on RDS - backups use virtual devices)
DECLARE @backuploc VARCHAR(200);
DECLARE @isRDS BIT = 0;

-- Detect RDS: RDS editions contain 'RDS'
IF CAST(SERVERPROPERTY('Edition') AS VARCHAR(100)) LIKE '%RDS%'
   SET @isRDS = 1;

IF @isRDS = 0
BEGIN
   USE msdb;
   SELECT @backuploc = REVERSE(SUBSTRING(REVERSE(physical_device_name),
                                        CHARINDEX('\', REVERSE(physical_device_name)),
                                        LEN(physical_device_name)))
   FROM   msdb.dbo.backupmediafamily
         INNER JOIN msdb.dbo.backupset 
             ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id
   WHERE  type = 'L'
         AND backup_start_date = (SELECT MAX(backup_start_date) FROM msdb.dbo.backupset);
END

-- Results table with per-file detail
IF OBJECT_ID('tempdb..#LogFileDetail') IS NOT NULL
   DROP TABLE #LogFileDetail;

CREATE TABLE #LogFileDetail
(
   DatabaseName        VARCHAR(128),
   LogicalFileName     VARCHAR(128),
   FileSizeGB          DECIMAL(18,2),
   SpaceUsedGB         DECIMAL(18,2),
   SpaceFreeGB         DECIMAL(18,2),
   PctUsed             DECIMAL(5,2),
   IsPercentGrowth     BIT,
   GrowthSetting       VARCHAR(50),
   PhysicalName        VARCHAR(500),
   RecoveryModel       VARCHAR(20),
   LogReuseWaitDesc    VARCHAR(60),
   VLFCount            INT
);

-- Check if sys.dm_db_log_info is available (SQL 2016 SP2+ / SQL 2017+)
DECLARE @hasDMV BIT = 0;
IF EXISTS (SELECT 1 FROM sys.system_objects WHERE name = 'dm_db_log_info')
   SET @hasDMV = 1;

DECLARE @dbname SYSNAME;
DECLARE @sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
   SELECT name 
   FROM sys.databases 
   WHERE state_desc = 'ONLINE'
    -- AND name NOT IN ('tempdb')  -- tempdb log behaves differently
   ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
   -- Build the VLF subquery based on what's available
   DECLARE @vlfJoin NVARCHAR(500);
   IF @hasDMV = 1
       SET @vlfJoin = 'LEFT JOIN (SELECT file_id, COUNT(*) AS VLFCount 
                        FROM sys.dm_db_log_info(DB_ID()) GROUP BY file_id) v
                        ON df.file_id = v.file_id';
   ELSE
       SET @vlfJoin = 'LEFT JOIN (SELECT 0 AS file_id, 0 AS VLFCount WHERE 1=0) v
                        ON df.file_id = v.file_id';

   SET @sql = '
   USE ' + QUOTENAME(@dbname) + ';
   INSERT INTO #LogFileDetail
   SELECT 
       DB_NAME()                                           AS DatabaseName,
       df.name                                             AS LogicalFileName,
       CAST(df.size * 8.0 / 1024 / 1024 AS DECIMAL(18,2))        AS FileSizeGB,
       CAST(FILEPROPERTY(df.name, ''SpaceUsed'') * 8.0 / 1024 / 1024 AS DECIMAL(18,2)) AS SpaceUsedGB,
       CAST((df.size - FILEPROPERTY(df.name, ''SpaceUsed'')) * 8.0 / 1024 / 1024 AS DECIMAL(18,2)) AS SpaceFreeGB,
       CASE WHEN df.size = 0 THEN 0
            ELSE CAST(FILEPROPERTY(df.name, ''SpaceUsed'') * 100.0 / df.size AS DECIMAL(5,2))
       END                                                 AS PctUsed,
       df.is_percent_growth,
       CASE WHEN df.is_percent_growth = 1 
            THEN CAST(df.growth AS VARCHAR) + '' %''
            ELSE CAST(CAST(df.growth * 8.0 / 1024 AS DECIMAL(10,0)) AS VARCHAR) + '' MB''
       END                                                 AS GrowthSetting,
       df.physical_name,
       d.recovery_model_desc,
       d.log_reuse_wait_desc,
       ISNULL(v.VLFCount, 0)
   FROM sys.database_files df
   CROSS JOIN sys.databases d
   ' + @vlfJoin + '
   WHERE df.type_desc = ''LOG''
     AND d.database_id = DB_ID();
   ';

   BEGIN TRY
       EXEC sp_executesql @sql;
   END TRY
   BEGIN CATCH
       PRINT 'Error on database: ' + @dbname + ' - ' + ERROR_MESSAGE();
   END CATCH

   FETCH NEXT FROM db_cursor INTO @dbname;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Final output with actionable statements
SELECT 
   d.DatabaseName,
   d.LogicalFileName,
   d.FileSizeGB                                            AS [Log Size (GB)],
   d.SpaceUsedGB                                           AS [Space Used (GB)],
   d.SpaceFreeGB                                           AS [Space Free (GB)],
   d.PctUsed                                               AS [Log Space Used (%)],
   d.VLFCount                                              AS [VLF Count],
   d.GrowthSetting                                         AS [Current Growth],
   CASE WHEN d.IsPercentGrowth = 0 
        THEN 'Fixed growth - best practice'
        ELSE 'Percent growth - see Modify statement --->'
   END                                                     AS LogGrowthNote,
   CASE WHEN d.IsPercentGrowth = 1
        THEN 'ALTER DATABASE ' + QUOTENAME(d.DatabaseName) + CHAR(13)
             + 'MODIFY FILE' + CHAR(13) 
             + '(NAME = ''' + d.LogicalFileName + ''',' + CHAR(13) 
             + 'FILEGROWTH = 512MB)'
        ELSE '--no change needed'
   END                                                     AS Modify_Log_File_Statement,
   d.RecoveryModel,
   d.LogReuseWaitDesc,
   CASE WHEN d.LogReuseWaitDesc = 'LOG_BACKUP' 
             THEN 'Please backup the log --->'
        WHEN d.LogReuseWaitDesc = 'ACTIVE_TRANSACTION' 
             THEN 'Active transaction must complete or be killed'
        WHEN d.LogReuseWaitDesc = 'REPLICATION'
             THEN 'Replication is holding the log - see Repl_Flush --->'
        ELSE 'No log backup required'
   END                                                     AS Log_Backup_Action,
   CASE WHEN @isRDS = 0
        THEN 'BACKUP LOG ' + QUOTENAME(d.DatabaseName) 
             + ' TO DISK = ''' + ISNULL(@backuploc, 'C:\')
             + d.DatabaseName + '_Tlog_backup.trn'' WITH STATS = 5'
        ELSE 'EXEC msdb.dbo.rds_backup_database @source_db_name=''' 
             + d.DatabaseName + ''', @s3_arn_to_backup_to=''arn:aws:s3:::your-bucket/' 
             + d.DatabaseName + '_Tlog_backup.trn'', @type=''LOG'';'
   END                                                     AS Backup_Statement,
   'USE ' + QUOTENAME(d.DatabaseName) + ';' + CHAR(13) 
       + 'DBCC SHRINKFILE (' + QUOTENAME(d.LogicalFileName, '''') 
       + ', 512)'                                          AS ShrinkFile_Statement,
   'USE ' + QUOTENAME(d.DatabaseName) + ';' + CHAR(13)
       + 'EXEC sp_repldone @xactid = NULL, @xact_segno = NULL, @numtrans = 0, @time = 0, @reset = 1;'
       + CHAR(13) + 'EXEC sp_replflush;' 
       + CHAR(13) + 'CHECKPOINT;'                          AS Repl_Flush,
   'ALTER DATABASE ' + QUOTENAME(d.DatabaseName) 
       + ' SET RECOVERY SIMPLE'                            AS Change_Recovery_to_Clear_Log,
   d.PhysicalName                                          AS Log_File_Location
FROM #LogFileDetail d
ORDER BY d.DatabaseName, d.FileSizeGB DESC;

DROP TABLE #LogFileDetail;