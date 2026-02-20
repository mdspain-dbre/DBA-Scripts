SELECT 
    t.NAME AS TableName,
    s.Name AS SchemaName,
    format(p.rows,'N0') AS RowCounts,
    (SUM(a.total_pages) * 8)/1024.0/1024.0 AS TotalSpaceGB, 
    (SUM(a.used_pages) * 8 )/1024.0/1024.0 AS UsedSpaceGB, 
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8/1024.0/1024.0 AS UnusedSpaceGB
FROM 
    sys.tables t
INNER JOIN      
    sys.indexes i ON t.OBJECT_ID = i.object_id
INNER JOIN 
    sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
INNER JOIN 
    sys.allocation_units a ON p.partition_id = a.container_id
LEFT OUTER JOIN 
    sys.schemas s ON t.schema_id = s.schema_id
WHERE 
    t.NAME NOT LIKE 'dt%' 
    AND t.is_ms_shipped = 0
    AND i.OBJECT_ID > 255 
--	and t.name in 
GROUP BY 
    t.Name, s.Name, p.Rows
ORDER BY p.rows  desc
/*
SELECT --COLUMN_NAME, DATA_TYPE, IS_NULLABLE, CHARACTER_MAXIMUM_LENGTH
STRING_AGG(COLUMN_NAME, ', ') AS ColumnNames,
String_AGG(DATA_TYPE,',')as datatypes
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Satellites_AvailabilityProperties' AND TABLE_SCHEMA = 'dbo';

--*/

--	187,951,255,296
--   15,715,229,188
--   27,537,809,974
	---1,008,607,008
	--126,613,316
--	248,975,059

--30,053,415,588
--374,084,158
--6,640,542,382


/*
SELECT 
    t.name AS TableName,
    s.name AS SchemaName,
	p.rows,
    SUM(a.total_pages) * 8 AS TotalSizeKB,
    SUM(a.used_pages) * 8 AS UsedSizeKB,
    SUM(a.data_pages) * 8 AS DataSizeKB
FROM sys.tables t
INNER JOIN sys.indexes i
    ON t.object_id = i.object_id
INNER JOIN sys.partitions p
    ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a
    ON p.partition_id = a.container_id
INNER JOIN sys.schemas s
    ON t.schema_id = s.schema_id
GROUP BY t.name, s.name, p.rows
ORDER BY TotalSizeKB DESC;

select min(effectivedate) from LinksLog with (nolock)



DBCC SHOW_STATISTICS ('Meta.MatchScores_Direct', '_WA_Sys_00000004_5F492382');


SELECT * FROM sys.dm_db_stats_histogram(OBJECT_ID('LinksLog'), 5);
*/
/*
LinksLog							dbo		188,503,797,319
MatchScores_Direct					Meta	 27,537,809,974
SatellitesLog						dbo		 15,668,982,209
Satellites							dbo		  7,022,909,379
MatchScores_Core					Meta	  6,786,913,504
Links								dbo		  6,781,018,413
HubChunkMapping						dbo		  4,476,355,675
SubgraphMapping						dbo		  3,239,187,345
PartitionSetItem					Meta	  3,213,316,395
PartitionSetItem					Meta	  3,213,316,394
DependencyItemHandle				Meta	  2,841,947,880
Hubs								dbo		  2,363,220,314
DependencyCompleted					Meta	  1,765,142,882
Satellites_TimeWindowProperties		dbo		  1,679,956,094
Satellites_VideoProperties			dbo		  1,175,276,559
Satellites_AvailabilityProperties	dbo		  1,077,451,397

SELECT 
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS RowCounts
FROM 
    sys.tables AS t
JOIN 
    sys.partitions AS p ON t.object_id = p.object_id
WHERE 
    p.index_id IN (0, 1)  -- 0 = Heap, 1 = Clustered Index
GROUP BY 
    t.schema_id, t.name
ORDER BY 
    RowCounts DESC;

*/


