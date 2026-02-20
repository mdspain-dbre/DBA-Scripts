SELECT 
SCHEMA_NAME(sys.objects.schema_id) AS [SchemaName] 
,OBJECT_NAME(sys.objects.object_id) AS [ObjectName] 
,[rows] 
,[data_compression_desc] 
,[index_id] as [IndexID_on_Table]
FROM sys.partitions 
INNER JOIN sys.objects 
ON sys.partitions.object_id = sys.objects.object_id 
WHERE data_compression > 0 
AND SCHEMA_NAME(sys.objects.schema_id) <> 'SYS' 
ORDER BY SchemaName, ObjectName


SELECT
    SCHEMA_NAME(o.schema_id) AS SchemaName,
    o.name AS TableName,
    i.name AS IndexName,
    p.data_compression_desc AS CompressionType,
    i.type_desc AS IndexType
FROM
    sys.partitions AS p
INNER JOIN
    sys.objects AS o ON p.object_id = o.object_id
INNER JOIN
    sys.indexes AS i ON p.object_id = i.object_id AND p.index_id = i.index_id
WHERE
    p.data_compression > 0 -- Filters for partitions with any compression (ROW or PAGE)
    AND o.is_ms_shipped = 0 -- Excludes system objects
ORDER BY
    SchemaName, TableName, IndexName;