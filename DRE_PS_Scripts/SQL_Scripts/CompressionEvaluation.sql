/*
The percentage of update operations on a specific table, index, or partition, relative to total operations on that object. 
The lower the value of U (that is, the table, index, or partition is infrequently updated), the better candidate it is for page compression.
*/
Drop table if exists #PercentUpdate
Drop table if exists #PercentScan

SELECT schema_name(o.schema_id) as SchemaName,
		o.name AS [Table_Name], x.name AS [Index_Name],
       i.partition_number AS [Partition],
       i.index_id AS [Index_ID], x.type_desc AS [Index_Type],
       i.leaf_update_count * 100.0 /
           (i.range_scan_count + i.leaf_insert_count
            + i.leaf_delete_count + i.leaf_update_count
            + i.leaf_page_merge_count + i.singleton_lookup_count
           ) AS [Percent_Update]
Into #PercentUpdate
FROM sys.dm_db_index_operational_stats (db_id(), NULL, NULL, NULL) i
JOIN sys.objects o ON o.object_id = i.object_id
JOIN sys.indexes x ON x.object_id = i.object_id AND x.index_id = i.index_id
WHERE (i.range_scan_count + i.leaf_insert_count
       + i.leaf_delete_count + leaf_update_count
       + i.leaf_page_merge_count + i.singleton_lookup_count) != 0
AND objectproperty(i.object_id,'IsUserTable') = 1
ORDER BY [Percent_Update] ASC

Select * ,
Case when Index_id > 0 
	then   'Alter Index '+QuoteName(Index_Name)+' On '+QuoteName(SchemaName)+'.'+QuoteName(Table_Name)+' Rebuild With (Online = Off,Data_Compression = Page,FillFactor = 90, MaxDop = 12);'
	Else   'Alter Table '+QuoteName(SchemaName)+'.'+QuoteName(Table_Name)+' Rebuild with (Online = Off, Data_Compression = Page,FillFactor = 90, MaxDop = 12);'
	end as IndexStmnt
from #PercentUpdate
where Percent_Update < 15

/*
The percentage of scan operations on a table, index, or partition, relative to total operations on that object. 
The higher the value of S (that is, the table, index, or partition is mostly scanned), the better candidate it is for page compression.
*/
SELECT schema_name(o.schema_id) as SchemaName,
		o.name AS [Table_Name], x.name AS [Index_Name],
       i.partition_number AS [Partition],
       i.index_id AS [Index_ID], x.type_desc AS [Index_Type],
       i.range_scan_count * 100.0 /
           (i.range_scan_count + i.leaf_insert_count
            + i.leaf_delete_count + i.leaf_update_count
            + i.leaf_page_merge_count + i.singleton_lookup_count
           ) AS [Percent_Scan]
Into #PercentScan
FROM sys.dm_db_index_operational_stats (db_id(), NULL, NULL, NULL) i
JOIN sys.objects o ON o.object_id = i.object_id
JOIN sys.indexes x ON x.object_id = i.object_id AND x.index_id = i.index_id
WHERE (i.range_scan_count + i.leaf_insert_count
       + i.leaf_delete_count + leaf_update_count
       + i.leaf_page_merge_count + i.singleton_lookup_count) != 0
AND objectproperty(i.object_id,'IsUserTable') = 1
ORDER BY [Percent_Scan] DESC


select * , 
Case when Index_id > 0 
	then   'Alter Index '+QuoteName(Index_Name)+' On '+QuoteName(SchemaName)+'.'+QuoteName(Table_Name)+' Rebuild With (Online = Off,Data_Compression = Page,FillFactor = 90, MaxDop = 12);'
	Else   'Alter Table '+QuoteName(SchemaName)+'.'+QuoteName(Table_Name)+' Rebuild with (Online = Off, Data_Compression = Page,FillFactor = 90, MaxDop = 12);'
	end as IndexStmnt
From #PercentScan 
where Percent_Scan > 75 


