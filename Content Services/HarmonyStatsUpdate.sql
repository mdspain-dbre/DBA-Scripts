/*
===============================================================================
HARMONY STATISTICS UPDATE PROCEDURE
===============================================================================
Procedure:  HarmonyStatsUpdate
Author:     Michael D'Spain
Version:    2.0 (August 27, 2025)

Purpose:
    Intelligently updates statistics on the Harmony database based on the 
    automatic threshold formula used by SQL Server Trace Flag 2371.

Algorithm:
    Uses SQRT(rows * 1000) as the modification threshold, which provides
    a dynamic threshold that scales with table size:
    - Small tables (10K rows): ~3,162 modifications trigger update
    - Medium tables (1M rows): ~31,623 modifications trigger update  
    - Large tables (100M rows): ~316,228 modifications trigger update

    Also captures stats where:
    - Modification counter > threshold BUT percent changed < 20%
    - Modification counter < threshold BUT percent changed > 20%

Parameters:
    @showstats  BIT = 1    Show current stats state without executing
    @print      BIT = 1    Print statements only, don't execute
    @seconds    INT = 500  Maximum runtime in seconds

Usage Examples:
    -- Preview mode: Show stats that would be updated
    EXECUTE HarmonyStatsUpdate @showstats = 1, @print = 1
    
    -- Execute mode: Update stats for ~500 seconds
    EXECUTE HarmonyStatsUpdate @showstats = 0, @print = 0, @seconds = 500
    
    -- Dry run: Print statements without executing
    EXECUTE HarmonyStatsUpdate @showstats = 0, @print = 1

Dependencies:
    - DBA.dbo.Stats_Log table for logging
    - sys.dm_db_stats_properties DMV

Output:
    Logs all updates to DBA.dbo.Stats_Log with start/end times
===============================================================================
*/

CREATE OR ALTER PROCEDURE HarmonyStatsUpdate  @showstats bit = 1,@print bit = 1,@seconds int = 500
AS
Set NoCount ON

--Return the current state of stats
--Declare @showstats bit 
--Set @showstats = 1

--Set @print to 1 to only print the Update Stat statements 
--Declare @print bit
--Set @print = 0

--Defines how long the process will run
--Declare @seconds int
--Set @seconds = 500

--Log all work to the DBA.Stats_log table
--DROP TEMP TABLE IF EXISTS
Drop Table if exists #Stats 

IF OBJECT_ID('DBA..STATS_LOG') IS NULL
    CREATE TABLE DBA..Stats_Log
    (
        ID BigInt IDENTITY PRIMARY KEY CLUSTERED
      , SchemaName VARCHAR(100)
      , TableName VARCHAR(200)
      , StatsName VARCHAR(200)
      , Update_stmt VARCHAR(500)
      , Rows BIGINT
      , Percent_Changed Float
      , Last_Updated DateTime2
      , Start_time DATETIME2
      , Finish_time DATETIME2
    )

--Existing data will be truncated 
IF EXISTS (SELECT * FROM dba..stats_log)
    TRUNCATE TABLE dba..stats_log

--Populate Stats table using sys.dm_db_stats_properties

SELECT sp.stats_id
     , sc.name                                                       AS SchemaName
     , OBJECT_NAME(s.object_id)                                      AS tablename
     , s.name                                                        AS stats_name
     , sp.last_updated
     , cast(sp.rows as bigint)                                       as rows
     , sp.rows_sampled
     , CAST(sp.rows_sampled AS Float) / CAST(sp.rows AS Float) * 100 AS Percentage_sampled
     , CASE
           WHEN sp.modification_counter = 0 THEN
               0
           ELSE
               CAST(sp.modification_counter AS Float) / CAST(sp.rows AS Float) * 100
       END                                                           AS Percent_changed
	,sp.modification_counter 
INTO #stats
FROM sys.stats                                                      AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    JOIN sys.tables  t
        ON t.object_id = s.object_id
    JOIN sys.schemas sc
        ON sc.schema_id = t.schema_id
ORDER BY s.object_id

/****************************************
--For reference 

SELECT *, SQRT(rows * 1000) as RowThreshod 
FROM #stats
order by percent_changed desc

SELECT *, SQRT(rows * 1000) as RowThreshod 
FROM #stats
where modification_counter >  SQRT(rows * 1000)

****************************************/

/****************************************
****************************************
REMOVE ALL EMPTY TABLES 
****************************************
****************************************/
DELETE #stats
WHERE (
          last_updated IS NULL
          AND ROWS IS NULL
          AND rows_sampled IS NULL
          AND Percentage_sampled IS NULL
          AND Percent_changed IS NULL
      )

/****************************************************************************************************************
*****************************************************************************************************************

Creating #StatsFinal to capture the statistics that need to be updated.  

Stats where mod counter is greater than the SQRT(rows*1000) threshold but less than 20% change 
Stats where mod counter is less than the SQRT(rows*1000) threshold but greater than 20% change 

**************************************************************************************************************
*************************************************************************************************************/
Drop table if exists #statslessthan20
Drop table if exists #statsgreaterthan20
Drop table if exists #StatsFinal

Select *,
       SQRT(rows * 1000) as Threshold
into #statslessthan20
from #stats
where modification_counter > SQRT(rows * 1000)
      and Percent_changed < 20
Select *,
       SQRT(rows * 1000) as Threshold
into #statsgreaterthan20
from #stats
where modification_counter < SQRT(rows * 1000)
      and Percent_changed > 20

select *
into #StatsFinal
from #statslessthan20
Union
Select *
from #statsgreaterthan20
order by tablename


--if you just want to see what stats the process captured 

If (@showstats = 1 and @print = 1)
Begin 
	
	Select * 
	from #StatsFinal
	order by rows 


End 


/****************************************

BEGIN THE LOOP MAGIC
LOOP THROUGH #STATS TABLE AND UPDATE STATS UPON DEFINED PARAMETERS
INSERT UPDATED STATS INTO STATSLOG TABLE 
	
CAPTURE CURRENT TIMESTAMP SO AS TO 
ALLOW THE PROCESS TO RUN FOR ONLY A SPECIFIED AMOUNT OF HOURS 

****************************************/
DECLARE @TIME DATETIME2
SET @TIME = getdate()

If(select count(*) from #StatsFinal) = 0
	GOTO NoWork --No Stats Need updating


DECLARE stats CURSOR LOCAL FAST_FORWARD FOR
SELECT schemaname
     , tablename
     , stats_name
     , last_updated
     , rows
     , rows_sampled
     , Percentage_sampled
     , Percent_changed
     , Modification_counter
FROM #StatsFinal
order by rows
OPEN stats
DECLARE @schema VARCHAR(100)
DECLARE @tablename VARCHAR(50)
DECLARE @stats_name VARCHAR(100)
DECLARE @last_update DATETIME
DECLARE @rows BIGINT
DECLARE @rows_sampled bigINT
DECLARE @percentage_sampled Float
DECLARE @percent_changed Float
DECLARE @Modification_Counter bigINT
DECLARE @CMD VARCHAR(1000)
DECLARE @counter BigInt = (
                              SELECT COUNT(*) FROM #StatsFinal
                          )
Declare @id int
DECLARE @iterator BigInt = 1
FETCH NEXT FROM stats
INTO @schema
   , @tablename
   , @stats_name
   , @last_update
   , @rows
   , @rows_sampled
   , @percentage_sampled
   , @percent_changed
   , @Modification_Counter
WHILE @@FETCH_STATUS = 0
BEGIN

    BEGIN TRY
        --check time at beginning of each iteration of the loop and send to catch block if running outside specified times 
        IF DATEDIFF(SECOND, @time, GetDate()) >= @seconds
        BEGIN
            RAISERROR('YOU RAN OUT OF TIME SUCKA', 11, 1)
        END
        ELSE
             Declare @message varchar(200)
			 Set @message = CHAR(13) + '/** ' + 'Updating...' + CAST(@iterator AS VARCHAR(6)) + '..of..'
                  + CAST(@counter AS VARCHAR(6)) + '...Statistics' + ' **/' + CHAR(13)
			
			Raiserror (@message,0,1) With NoWait


        SELECT @CMD = 'UPDATE STATISTICS ' + QUOTENAME(@schema) + +'.' + QUOTENAME(@tablename) + '(' + QUOTENAME(@stats_name)+ ');'

        If @print = 1
        Begin
            PRINT @cmd
        End
        Else
			Begin
		Declare @Startime datetime2
		Set @Startime = getdate()

        INSERT INTO dba..Stats_log
        (
            schemaname
          , tablename
          , statsname
          , Start_time
          , rows
          , Percent_Changed
          , Last_Updated
        )
        VALUES
        (@schema, @tablename, @stats_name, @Startime, @rows, @percent_changed, @last_update);
        
		EXEC (@cmd)

			UPDATE dba..Stats_log
				SET finish_time = getdate()
				  , Update_Stmt = @CMD
				WHERE Start_time = @Startime
					  AND  statsName = @stats_name
					  AND tablename = @tablename
					  AND Schemaname = @schema
			End
        
		SET @iterator = @iterator + 1
        
		FETCH NEXT FROM stats
        INTO @schema
           , @tablename
           , @stats_name
           , @last_update
           , @rows
           , @rows_sampled
           , @percentage_sampled
           , @percent_changed
           , @Modification_Counter
    END TRY
    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS ErrorMessage
        BREAK
    END CATCH
END
CLOSE stats
DEALLOCATE stats

Nowork:
If (Select count(*) from #StatsFinal) = 0
	Begin 
	Print 'No Stats need updating'
	End 

