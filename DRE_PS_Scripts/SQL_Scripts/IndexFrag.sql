/***************************


select * from DBA.dbo.Stats_Log

select * from dba.dbo.CommandLog
where CommandType like '%Index%' and DatabaseName = 'Harmony'
order by EndTime desc 


truncate table dba.dbo.fragstats

insert into dba.dbo.fragstats
SELECT S.name as 'Schema',
T.name as 'Table',
I.name as 'Index',
DDIPS.*
FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, 'Detailed') AS DDIPS
INNER JOIN sys.tables T on T.object_id = DDIPS.object_id
INNER JOIN sys.schemas S on T.schema_id = S.schema_id
INNER JOIN sys.indexes I ON I.object_id = DDIPS.object_id
AND DDIPS.index_id = I.index_id
WHERE DDIPS.database_id = DB_ID()
and I.name is not null
--AND DDIPS.avg_fragmentation_in_percent > 50
--ORDER BY DDIPS.avg_fragmentation_in_percent desc


**********************************************************/

Drop table if exists #fragstats
Drop table if exists #usagestats
		
select * 
into #fragstats
from DBA.dbo.fragstats
where index_level = 0
order by record_count desc

SELECT * 
--i.name, s.user_seeks, s.user_scans, s.user_lookups, s.user_updates
--into #UsageStats
from  sys.indexes AS i
 join sys.dm_db_index_usage_stats s 
	ON s.object_id = i.object_id AND s.index_id = i.index_id
where s.database_id = 11 and s.index_id <> 0
order by user_seeks desc


select * from #UsageStats 

select * from #fragstats f
left join  #UsageStats U on f. [index] = u.[Index]
order by u.user_updates

select * 
from DBA.dbo.fragstats




SELECT
	phys.[Index],
    DB_NAME(usage.database_id) AS database_name,
    OBJECT_NAME(usage.object_id, usage.database_id) AS object_name,
    usage.index_id,
    usage.user_seeks,
    usage.user_scans,
    usage.user_lookups,
    usage.user_updates,
    phys.avg_fragmentation_in_percent,
    phys.page_count	
FROM sys.dm_db_index_usage_stats AS usage
JOIN DBA.dbo.fragstats AS phys
ON usage.database_id = phys.database_id
   AND usage.object_id = phys.object_id
   AND usage.index_id = phys.index_id
WHERE phys.index_level = 0
ORDER BY phys.avg_page_space_used_in_percent DESC;



