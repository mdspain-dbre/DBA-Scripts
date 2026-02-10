USE [DBA]
GO
/*
===============================================================================
HARMONY INDEX MAINTENANCE PROCEDURE
===============================================================================
Procedure:  [IndexMaint].[HarmonyIndexMaint]
Author:     Michael DSpain
Created:    January 7, 2026

Purpose:
    Performs intelligent index rebuilds on the Harmony database based on 
    page density (avg_page_space_used_in_percent) collected from the 
    fragmentation stats in DBA.dbo.FragStats.

Algorithm:
    1. Truncates and repopulates DBA.IndexMaint.HarmonyIndexes from FragStats
    2. Filters indexes based on:
       - Page density < 90% (indexes with wasted space)
       - Page count >= 1000 (excludes very small indexes)
    3. Excludes MatchScores_Direct table (27B rows - use stats update instead)
    4. Rebuilds indexes with:
       - ONLINE = OFF (faster, but requires maintenance window)
       - FILLFACTOR = 95 (leaves 5% free space per page)
       - MAXDOP = 32 (parallel rebuild)
    5. Tracks progress in DBA.IndexMaint.HarmonyIndexes with start/end times

Parameters:
    @print      BIT = 1    1 = Print only (dry run), 0 = Execute rebuilds
    @TimeLimit  INT = 360  Maximum runtime in minutes

Usage Examples:
    -- Dry run: Show what would be rebuilt
    EXECUTE [IndexMaint].[HarmonyIndexMaint] @print = 1
    
    -- Execute: Rebuild indexes for up to 6 hours
    EXECUTE [IndexMaint].[HarmonyIndexMaint] @print = 0, @TimeLimit = 360
    
    -- Execute: Rebuild for 2 hours
    EXECUTE [IndexMaint].[HarmonyIndexMaint] @print = 0, @TimeLimit = 120

Dependencies:
    - DBA.dbo.FragStats (populated by HarmonyIndexFragCollection.sql)
    - DBA.IndexMaint.HarmonyIndexes (staging table for rebuild work)

Notes:
    - Process may run slightly longer than @TimeLimit if a rebuild is in progress
    - Indexes are processed smallest (page count) first for quick wins
    - RebuildStatus = 1 indicates successful rebuild
===============================================================================
*/
/****** Object:  StoredProcedure [IndexMaint].[HarmonyIndexMaint]    Script Date: 1/7/2026 5:42:23 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [IndexMaint].[HarmonyIndexMaint] @print bit = 1, @TimeLimit int = 360
AS


/*********************************
*********************************
Set @print = 0 to execute the work

@TimeLImit is in Minutes
	How long do you want the process to run
	Process can run longer that the specified number of minutes depending on when the last rebuild runs prior to the timelimit
*********************************
*********************************/

Declare @CollectionTime varchar(23) = CONVERT(VARCHAR(23), GETDATE(), 121)



/***************
For Testing
declare @print bit 
set @print = 1
****************/

Set NoCount ON

--Reset DBA.IndexMaint.HarmonyIndex
RAISERROR('--Truncating DBA.IndexMaint.HarmonyIndexes' , 0, 1) WITH NOWAIT
Truncate Table DBA.IndexMaint.HarmonyIndexes;

Insert DBA.IndexMaint.HarmonyIndexes
(
    SchemaName,
    TableName,
    IndexName,
    AVG_PageDensity,
    AVG_PageCount,
    IndexStmnt
)
select [schema],
       [table],
       [index],
       AVG(avg_page_space_used_in_percent) as AVG_PageDensity,
       AVG(Page_count) as AVG_PageCount,
       Case
           when Index_id > 0 then
               'Alter Index ' + [Index] + ' On ' +'Harmony.'+ [Schema] + '.' + [Table]
               + ' Rebuild With (Online = Off,FillFactor = 95, MaxDop = 32);'
           Else
               'Alter Table ' + [Schema] + '.' + [Table] + ' Rebuild with (Online = Off,FillFactor = 90, MaxDop = 32);'
       end as IndexStmnt
from DBA.dbo.FragStats
where CollectionTime =
(
    select max(CollectionTime) from dba.dbo.fragstats
)
Group By [Schema],
         [Table],
         [Index],
         [index_id]

--Remove Indexes that are in a healthy state in terms of page density
--Remove very small indexes 

Delete from DBA.IndexMaint.HarmonyIndexes
where AVG_PageDensity > 90
      or AVG_PageCount < 1000

--Remove indexes from this table as the table is 27billion rows 
--Update Stats will work. 

Delete from DBA.IndexMaint.HarmonyIndexes
where TableName = 'MatchScores_Direct'

--Counter for how many indexes we are working on 
DECLARE @Indexcount int
Set @Indexcount =
(
    Select count(*) from DBA.IndexMaint.HarmonyIndexes
)

--Used in print statements 
DECLARE @IndexIterator int = 1

--Used to determine start time of the index maint run 
Declare @StartTime datetime2
Set @StartTime = getdate()


DECLARE CS CURSOR FORWARD_ONLY STATIC FOR
Select [SchemaName],
       [TableName],
       [IndexName],
       AVG_PageCount,
       AVG_PageDensity,
       INdexStmnt
from DBA.IndexMaint.HarmonyIndexes
order by AVG_PageCount asc

-- Declare variables to hold the values
DECLARE @SchemaName varchar(15);
DECLARE @TableName varchar(60);
Declare @IndexName varchar(200);
DECLARE @IndexStmnt varchar(500);
DECLARE @pagecount int;
DECLARE @pagedensity float

-- Open the cursor
OPEN CS;

-- Fetch the first row
FETCH NEXT FROM CS
INTO @SchemaName,
     @TableName,
     @IndexName,
     @pagecount,
     @pagedensity,
     @INdexStmnt;

-- Loop through the rows
WHILE @@FETCH_STATUS = 0
BEGIN

	/*********************************
	*********************************
	*********************************
	Building messaage output
	*********************************
	********************************* 
	**********************************/
    
	--Counter that will be printed to screen on how many indexes to be rebuilt
    Declare @Indexcountmessage varchar(100)
    Set @Indexcountmessage = '--'+cast(@IndexIterator as varchar(3)) + '..of..' + Cast(@Indexcount as varchar(10))


    Declare @IndexMessage varchar(600)
    Set @IndexMessage
        ='--Working on--->' + QuoteName(@SchemaName) + '.' + QuoteName(@TableName) + char(13) + 
		+'--'+@IndexStmnt + char(13)+
		'--page count.. ' + cast(@pagecount as varchar(20)) + char(13) + 
		'--page density.. '+ cast(@pagedensity as varchar(20)) + char(13) 

    --Keep track of the status of the rebuild work

Declare @IndexRebuildStartTime varchar(23) = (Select CONVERT(VARCHAR(23), GETDATE(), 121))

    Declare @UpdateRebuildStartTime varchar(600)
    Set @UpdateRebuildStartTime
        = 'Update DBA.IndexMaint.HarmonyIndexes ' + char(13) + 'Set StartTime = '+''''+@IndexRebuildStartTime+''''+',CollectionTime = '+''''+@CollectionTime+'''' + Char(13)
          + 'Where SchemaName = ' + '''' + @SchemaName + '''' + ' and TableName = ' + '''' + @TableName + ''''
          + char(13) + 'and IndexName = ' + '''' + @IndexName + '''' + ';' + char(13) + '/**************************/'

/*********************************
*********************************
Set @print = 0 to execute the work
*********************************
*********************************/

    if @print = 0
    Begin

            RAISERROR(@Indexcountmessage, 0, 1) WITH NOWAIT
            RAISERROR(@IndexMessage, 0, 1) WITH NOWAIT

			Execute (@UpdateRebuildStartTime) --populate the start time of each index rebuild
            Execute (@IndexStmnt)

			Declare @IndexRebuildEndTime varchar(23) = (Select CONVERT(VARCHAR(23), GETDATE(), 121))
			Declare @UpdateRebuildEndTime varchar(600) 
				Set @UpdateRebuildEndTime
					= 'Update DBA.IndexMaint.HarmonyIndexes ' + char(13) + 'Set RebuildStatus = 1, EndTime = '+''''+@IndexRebuildEndTime+'''' + Char(13)
					  + 'Where SchemaName = ' + '''' + @SchemaName + '''' + ' and TableName = ' + '''' + @TableName + ''''
					  + char(13) + 'and IndexName = ' + '''' + @IndexName + '''' + ';' + char(13) + '/**************************/'

            Execute (@UpdateRebuildEndTime) --set RebuildStatus =1 and set EndTime for each Index Rebuild
     End

    if @print = 1
    Begin
        RAISERROR(@Indexcountmessage, 0, 1) WITH NOWAIT
		RAISERROR(@UpdateRebuildStartTime,0,1) WITH NOWAIT
        RAISERROR(@IndexMessage, 0, 1) WITH NOWAIT

		Declare @PrintOnlyIndexRebuildEndTime varchar(23) = (Select CONVERT(VARCHAR(23), GETDATE(), 121))
		Declare @PrintOnlyUpdateRebuildEndTime varchar(600) 
			Set @PrintOnlyUpdateRebuildEndTime
				= 'Update DBA.IndexMaint.HarmonyIndexes ' + char(13) + 'Set RebuildStatus = 1, EndTime = '+''''+@PrintOnlyIndexRebuildEndTime+'''' + Char(13)
				  + 'Where SchemaName = ' + '''' + @SchemaName + '''' + ' and TableName = ' + '''' + @TableName + ''''
				  + char(13) + 'and IndexName = ' + '''' + @IndexName + '''' + ';' + char(13) + '/**************************/'

        RAISERROR(@PrintOnlyUpdateRebuildEndTime, 0, 1) WITH NOWAIT
		RAISERROR('------------------------------------------------------', 0, 1) WITH NOWAIT

    End
    --Setting Time limit on how long this process can run
    If
    (Select datediff(minute, @StartTime, getdate())) > @TimeLimit
    Begin
        RAISERROR('Times Up!!', 0, 1) WITH NOWAIT
        --Control the flow 
        GOTO CursorBreak
    End

    Set @IndexIterator = @IndexIterator + 1

    -- Fetch the next row
    FETCH NEXT FROM CS
    INTO @SchemaName,
         @TableName,
         @IndexName,
         @pagecount,
         @pagedensity,
         @INdexStmnt;
END;

--Control the Flow with the Label
CursorBreak:
-- Clean up
CLOSE CS;
DEALLOCATE CS;




