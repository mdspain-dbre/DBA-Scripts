Use Harmony
GO

truncate table dba.dbo.fragstats

Declare @CollectionTime datetime
Set @CollectionTime = getdate()

insert into dba.dbo.fragstats
SELECT S.name as 'Schema',
T.name as 'Table',
I.name as 'Index',
DDIPS.*, @CollectionTime
FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, 'Detailed') AS DDIPS
INNER JOIN sys.tables T on T.object_id = DDIPS.object_id
INNER JOIN sys.schemas S on T.schema_id = S.schema_id
INNER JOIN sys.indexes I ON I.object_id = DDIPS.object_id
AND DDIPS.index_id = I.index_id
WHERE DDIPS.database_id = DB_ID()

