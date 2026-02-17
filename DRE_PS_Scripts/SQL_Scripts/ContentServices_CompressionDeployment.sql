/*************************
The percentage of update operations on a specific table, index, or partition, relative to total operations on that object. 
The lower the value of U (that is, the table, index, or partition is infrequently updated), the better candidate it is for page compression.
*************************/

/*************************
Set statistics profile on if you want to monitor progress of Rebuild 
*************************/

Set statistics profile on
Set NoCount on 

Drop table if exists #PercentUpdate;
Drop table if exists #PercentScan;
Drop table if exists #TableSize;
Drop table if exists #PercentScan_Final;
Drop table if exists #PercentUpdate_Final;

/*************************
Set print to zero to execute the Rebuilds
*************************/

Declare @print bit = 1

/*************************
Getting rows counts for all tables in Harmony
this helps us determine how large the table or index is 
*************************/

SELECT t.NAME AS TableName,
       s.Name AS SchemaName,
       p.rows AS RowCounts,
       (SUM(a.total_pages) * 8) / 1024.0 / 1024.0 AS TotalSpaceGB,
       (SUM(a.used_pages) * 8) / 1024.0 / 1024.0 AS UsedSpaceGB,
       (SUM(a.total_pages) - SUM(a.used_pages)) * 8 / 1024.0 / 1024.0 AS UnusedSpaceGB
into #TableSize
FROM sys.tables t
    INNER JOIN sys.indexes i
        ON t.OBJECT_ID = i.object_id
    INNER JOIN sys.partitions p
        ON i.object_id = p.OBJECT_ID
           AND i.index_id = p.index_id
    INNER JOIN sys.allocation_units a
        ON p.partition_id = a.container_id
    LEFT OUTER JOIN sys.schemas s
        ON t.schema_id = s.schema_id
WHERE t.NAME NOT LIKE 'dt%'
      AND t.is_ms_shipped = 0
      AND i.OBJECT_ID > 255
--	  AND p.data_compression = 0
--	and t.name in 
GROUP BY t.Name,
         s.Name,
         p.Rows
ORDER BY p.rows desc

/*************************
Finding the percentage of updates to a table or index 
*************************/

SELECT schema_name(o.schema_id) as SchemaName,
       o.name AS [Table_Name],
       x.name AS [Index_Name],
       i.partition_number AS [Partition],
       i.index_id AS [Index_ID],
       x.type_desc AS [Index_Type],
       i.leaf_update_count * 100.0
       / (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + i.leaf_update_count
          + i.leaf_page_merge_count + i.singleton_lookup_count
         ) AS [Percent_Update], 
		 p.data_compression, 
		 p.data_compression_desc
Into #PercentUpdate
FROM sys.dm_db_index_operational_stats(db_id(), NULL, NULL, NULL) i
    JOIN sys.objects o
        ON o.object_id = i.object_id
    JOIN sys.indexes x
        ON x.object_id = i.object_id
           AND x.index_id = i.index_id
	JOIN sys.partitions p on p.object_id = o.object_id and p.index_id = i.index_id
WHERE (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + leaf_update_count + i.leaf_page_merge_count
       + i.singleton_lookup_count
      ) != 0
      AND objectproperty(i.object_id, 'IsUserTable') = 1
ORDER BY [Percent_Update] ASC

/*************************
Gettings objects with update rate less than 15%
*************************/



select U.SchemaName,
       U.Table_Name,
       U.Percent_Update,
       U.Index_Name,
	   U.Index_ID,
       s.RowCounts,
       s.TotalSpaceGB,
       s.UnusedSpaceGB,
	   u.data_compression, 
	   u.data_compression_desc,
	   row_number() over(partition by table_name, index_name order by table_name)  as indexcount
into #PercentUpdate_Final
from #PercentUpdate u
    Join #TableSize s
        on u.SchemaName = s.SchemaName
           and u.Table_Name = s.TableName
Where U.Percent_Update < 15 and data_compression =0
and Table_Name <> 'MatchScores_Direct'
Order by U.Percent_Update


Select *
from #PercentUpdate_Final
where indexcount = 1
order by rowcounts  



/*************************
The percentage of scan operations on a table, index, or partition, relative to total operations on that object. 
The higher the value of S (that is, the table, index, or partition is mostly scanned), the better candidate it is for page compression.
*************************/

SELECT schema_name(o.schema_id) as SchemaName,
       o.name AS [Table_Name],
       x.name AS [Index_Name],
       i.partition_number AS [Partition],
       i.index_id AS [Index_ID],
       x.type_desc AS [Index_Type],
       i.range_scan_count * 100.0
       / (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + i.leaf_update_count
          + i.leaf_page_merge_count + i.singleton_lookup_count
         ) AS [Percent_Scan],
		p.data_compression, 
		p.data_compression_desc
Into #PercentScan
FROM sys.dm_db_index_operational_stats(db_id(), NULL, NULL, NULL) i
    JOIN sys.objects o
        ON o.object_id = i.object_id
    JOIN sys.indexes x
        ON x.object_id = i.object_id
           AND x.index_id = i.index_id
	JOIN sys.partitions p on p.object_id = o.object_id and p.index_id = i.index_id
WHERE (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + leaf_update_count + i.leaf_page_merge_count
       + i.singleton_lookup_count
      ) != 0
      AND objectproperty(i.object_id, 'IsUserTable') = 1
ORDER BY [Percent_Scan] DESC

/*************************
Grabbing objedct with an greater 75% scan rate
*************************/

select ps.SchemaName,
       ps.Table_Name,
       ps.Percent_Scan,
       ps.Index_Name,
	   ps.Index_ID,
       s.RowCounts,
       s.TotalSpaceGB,
       s.UnusedSpaceGB,
	   ps.data_compression, 
	   ps.data_compression_desc,
	   row_number() over(partition by table_name, index_name order by table_name)  as indexcount
Into #PercentScan_Final
from #PercentScan ps
    Join #TableSize s
        on ps.SchemaName = s.SchemaName
           and ps.Table_Name = s.TableName
Where ps.Percent_Scan > 75 and Table_Name <> 'MatchScores_Direct'
Order by ps.Percent_Scan desc

Select *
from #PercentScan_Final
where indexcount = 1
order by rowcounts  


/************************
************************
************************
Scan section
************************
************************
************************/

RAISERROR('/***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('High Scan Tables!!!!!!!!!!!', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('/***********************************/', 0, 1) WITH NOWAIT

/************************
Scan count interators for printing progress to screen
************************/

Declare @scancount int
Set @scancount = (Select count(*) from #PercentScan_Final where Table_Name <> 'MatchScores_Direct')
Declare @scaniterator int = 1

/************************
Declare cursor logic
Excluding the MatchScores_Direct table for now.  28billion rows
************************/

DECLARE CS CURSOR FORWARD_ONLY STATIC FOR
select SchemaName,
       Table_Name,
       Case
           when Index_id > 0 then
               'Alter Index ' + QuoteName(Index_Name) + ' On ' + QuoteName(SchemaName) + '.' + QuoteName(Table_Name)
               + ' Rebuild With (Online = Off,Data_Compression = Page,FillFactor = 90, MaxDop = 24);'
           Else
               'Alter Table ' + QuoteName(SchemaName) + '.' + QuoteName(Table_Name)
               + ' Rebuild with (Online = Off, Data_Compression = Page,FillFactor = 90, MaxDop = 24);'
       end as IndexStmnt
From #PercentScan_Final
where indexcount = 1
order by rowcounts  


-- Declare variables to hold the values
DECLARE @Scan_SchemaName varchar(15);
DECLARE @Scan_Table_Name varchar(60);
DECLARE @Scan_IndexStmnt varchar(500);
-- Open the cursor
OPEN CS;

-- Fetch the first row
FETCH NEXT FROM CS
INTO @Scan_SchemaName,
     @Scan_Table_Name,
     @Scan_IndexStmnt;

-- Loop through the rows
WHILE @@FETCH_STATUS = 0
BEGIN
    
	Declare @Scan_number_message varchar(100)
	Set @Scan_number_message = Cast(@scaniterator as varchar(3))+'..of..'+ cast(@scancount as varchar(3))
   
   Declare @Scan_message varchar(600)
    Set @Scan_message
        = 'Working on--->' + QuoteName(@Scan_SchemaName) + '.' + QuoteName(@Scan_Table_Name) + char(13) + @Scan_IndexStmnt + char(13)
          + '/**************************/'

	RAISERROR(@Scan_number_message, 0, 1) WITH NOWAIT
    RAISERROR(@Scan_message, 0, 1) WITH NOWAIT

/************************
Print block
************************/
	if @print = 0
	Begin
	Print (@Scan_IndexStmnt)
    --Execute (@Scan_IndexStmnt)
	End 

/***********************
Increment @scaniterator by 1
************************/
	Set @scaniterator = @scaniterator + 1

    -- Fetch the next row
    FETCH NEXT FROM CS
    INTO @Scan_SchemaName,
         @Scan_Table_Name,
         @Scan_IndexStmnt;
END;

-- Clean up
CLOSE CS;
DEALLOCATE CS;

RAISERROR('/***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('Low Update Tables!!!!!!!!!!!', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('***********************************', 0, 1) WITH NOWAIT
RAISERROR('/***********************************/', 0, 1) WITH NOWAIT

/************************
Setting a count variable to print to the screen to show progress
*************************/

Declare @updatecount int 
Set @updatecount = (Select count(*) from #PercentUpdate_Final)

declare @updateiterator int = 1

-- Declare the cursor
DECLARE CS CURSOR FORWARD_ONLY STATIC FOR
Select SchemaName,
       Table_Name,
       Case
           when Index_id > 0 then
               'Alter Index ' + QuoteName(Index_Name) + ' On ' + QuoteName(SchemaName) + '.' + QuoteName(Table_Name)
               + ' Rebuild With (Online = Off,Data_Compression = Page,FillFactor = 90, MaxDop = 24);'
           Else
               'Alter Table ' + QuoteName(SchemaName) + '.' + QuoteName(Table_Name)
               + ' Rebuild with (Online = Off, Data_Compression = Page,FillFactor = 90, MaxDop = 24);'
       end as IndexStmnt
from #PercentUpdate_Final
where indexcount = 1
order by rowcounts  

-- Declare variables to hold the values
DECLARE @Update_SchemaName varchar(15);
DECLARE @Update_Table_Name varchar(60);
DECLARE @Update_IndexStmnt varchar(500);
-- Open the cursor
OPEN CS;

-- Fetch the first row
FETCH NEXT FROM CS
INTO @Update_SchemaName,
     @Update_Table_Name,
     @Update_IndexStmnt;

-- Loop through the rows
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Do something with the data
	Declare @Updatecountmessage varchar(100)
	Set @Updatecountmessage = cast(@updateiterator as varchar(3)) +'..of..'+Cast(@updatecount as varchar(3)) 


    Declare @UpdateMessage varchar(600)
    Set @UpdateMessage
        = 'Working on--->' + QuoteName(@Update_SchemaName) + '.' + QuoteName(@Update_Table_Name) + char(13) + @Update_IndexStmnt + char(13)
          + '/**************************/'
	
	RAISERROR(@Updatecountmessage, 0, 1) WITH NOWAIT
	RAISERROR(@UpdateMessage, 0, 1) WITH NOWAIT

    
	if @print = 0
	Begin
	Print (@Update_IndexStmnt)
	Execute (@Update_IndexStmnt)
	end 

Set @updateiterator = @updateiterator +1

    -- Fetch the next row
    FETCH NEXT FROM CS
    INTO @Update_SchemaName,
         @Update_Table_Name,
         @Update_IndexStmnt;
END;

-- Clean up
CLOSE CS;
DEALLOCATE CS;

