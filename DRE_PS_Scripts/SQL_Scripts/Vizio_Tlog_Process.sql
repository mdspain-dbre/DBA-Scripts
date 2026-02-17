DECLARE @backuploc VARCHAR(200);

USE msdb;
SELECT  @backuploc=  REVERSE(SUBSTRING(REVERSE(physical_device_name),
                                       CHARINDEX('\',
                                                 REVERSE(physical_device_name)),
                                       LEN(physical_device_name)))
FROM    msdb.dbo.backupmediafamily
        INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id
WHERE    type = 'L'
        AND backup_start_date = ( SELECT    MAX(backup_start_date)
                                  FROM      msdb.dbo.backupset
                                );

SET NOCOUNT ON 

IF OBJECT_ID('tempdb..#TempForLogSpace') IS NOT NULL
    BEGIN
        DROP TABLE #TempForLogSpace;
    END;

CREATE TABLE #TempForLogSpace
    (
      DataBaseName VARCHAR(100) ,
      LogSize NUMERIC(18, 4) ,
      LOgPercentage NUMERIC(18, 4) ,
      Status INT
    );

INSERT  INTO #TempForLogSpace
        EXEC ( 'DBCC sqlperf(logspace) WITH NO_INFOMSGS'
            );	

SELECT  sd.name AS dbName,
		smf.name AS 'Logical Log File Name' ,
        CASE WHEN smf.is_percent_growth = 0
             THEN 'file is set to a fixed value and is considered best practice'
             WHEN smf.is_percent_growth = 1
             THEN 'See modify_log_file_statement---->'
        END AS log_growth_setting ,
        CASE WHEN smf.is_percent_growth = 0 THEN '--no alter DB statement needed'
             WHEN smf.is_percent_growth = 1
             THEN 'ALTER DATABASE '+sd.name + CHAR(13)
                  + 'MODIFY FILE ' + CHAR(13) + '(NAME = ''' + smf.name
                  + ''',' + CHAR(13) + 'FILEGROWTH = 512MB)'
        END AS Modify_Log_File_statement ,
        t.LogSize / 1024 AS 'Log Size (GB)' ,
        t.LOgPercentage AS 'Log Space Used(%)' ,
        CASE WHEN sd.log_reuse_wait_desc = 'LOG_BACKUP'
             THEN 'please backup the log---->'
  WHEN sd.log_reuse_wait_desc = 'ACTIVE_TRANSACTION'
THEN 'you have an active transaction..it must complete or be killed before log will clear'
ELSE 'no log backup required'
        END AS Log_Backup_Action ,
sd.log_reuse_wait_desc ,
sd.recovery_model_desc,
        'Backup log '+sd.name +' to disk = ''' + ISNULL(@backuploc,'c:\')
        +sd.name +'_Tlog_backup.trn'' with stats = 5' AS Backup_Statement ,
        'Use ' + t.DataBaseName + ';' + CHAR(13) + 'DBCC SHRINKFILE ('
        + smf.name + ' , 512)' AS SHRINKFILE_statement ,
		'Use ' + t.DataBaseName+';' + CHAR(13) +'EXEC sp_repldone @xactid = NULL, @xact_segno = NULL, @numtrans = 0, @time = 0, @reset = 1;'
		+CHAR(13)+'EXEC sp_replflush;'+CHAR(13)+'checkpoint;' AS Repl_Flush,
        'Alter Database '+sd.name+' SET Recovery Simple' AS Change_Recovery_Model_to_Clear_log ,
        smf.physical_name AS Log_File_Location
FROM    #TempForLogSpace AS t
        INNER JOIN sys.databases AS sd ON t.DataBaseName = sd.name
        INNER JOIN sys.master_files smf ON sd.database_id = smf.database_id
WHERE   smf.type_desc <> 'rows'
     --   AND sd.database_id > 4
ORDER BY [Log Size (GB)] desc


--select getdate()
--dbcc opentran

--dbcc inputbuffer (161)

/*
-- Create the temporary table to accept the results.
Drop table if exists #OpenTranStatus;

CREATE TABLE #OpenTranStatus (
   ActiveTransaction VARCHAR(25),
   Details sql_variant
   );
-- Execute the command, putting the results in the table.
INSERT INTO #OpenTranStatus
   EXEC ('DBCC OPENTRAN WITH TABLERESULTS, NO_INFOMSGS');
  
-- Display the results.
SELECT * FROM #OpenTranStatus;
GO

*/
