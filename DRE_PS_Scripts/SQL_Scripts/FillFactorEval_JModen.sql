WITH cteStats
AS ( --===== This CTE is used mostly to rename some of the very long names in the DMF.

   SELECT DBName = DB_NAME(),
          ObjectID = ips.object_id,
          IndexID = ips.index_id,
          FragPct = CONVERT(INT, ips.avg_fragmentation_in_percent),
          AvgFragSize = avg_fragment_size_in_pages,
          PageDensity = ips.avg_page_space_used_in_percent,
          PageCnt = ips.page_count,
          RowCnt = ips.record_count,
          CurSizeMB = ips.page_count / 128 --Integer math produces whole numbers here.

   FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
   WHERE ips.index_id > 0 --NOT a HEAP

         AND ips.page_count > 128 --This is 1 MB or 16 Extents and could be parameterized.
   )
SELECT stats.DBName,
       SchemaName = OBJECT_SCHEMA_NAME(stats.ObjectID),
       ObjectName = OBJECT_NAME(stats.ObjectID),
       stats.ObjectID,
       IndexName = idx.name,
       stats.IndexID,
       CurFillFactor = idx.fill_factor,
       stats.FragPct,
       stats.AvgFragSize,
       stats.PageDensity,
       stats.PageCnt,
       stats.RowCnt,
       stats.CurSizeMB,
       SavingsMBCur = CONVERT(
                                 INT,
                                 (stats.PageCnt
                                  - (stats.PageDensity / ISNULL(NULLIF(idx.fill_factor, 0), 100) * stats.PageCnt)
                                 )
                                 / 128.0
                             ),
       SavingsMB070 = CONVERT(INT, (stats.PageCnt - (stats.PageDensity / 70 * stats.PageCnt)) / 128.0),
       SavingsMB080 = CONVERT(INT, (stats.PageCnt - (stats.PageDensity / 80 * stats.PageCnt)) / 128.0),
       SavingsMB090 = CONVERT(INT, (stats.PageCnt - (stats.PageDensity / 90 * stats.PageCnt)) / 128.0),
       SavingsMB100 = CONVERT(INT, (stats.PageCnt - (stats.PageDensity / 100 * stats.PageCnt)) / 128.0)
FROM cteStats stats
    JOIN sys.indexes idx
        ON stats.ObjectID = idx.object_id
           AND stats.IndexID = idx.index_id;



select 
       SavingsMBCur = CONVERT(
                                 INT,
                                 (Page_Count 
                                  - (avg_page_space_used_in_percent / ISNULL(NULLIF(80, 0), 100) * Page_Count)
                                 )
                                 / 128.0/1024.0
                             ),
       SavingsGB070 = CONVERT(INT, (Page_Count - (avg_page_space_used_in_percent / 70 *  Page_Count)) / 128.0/1024.0),
       SavingsGB080 = CONVERT(INT, (Page_Count - (avg_page_space_used_in_percent / 80 *  Page_Count)) / 128.0/1024.0),
       SavingsGB090 = CONVERT(INT, (Page_Count - (avg_page_space_used_in_percent / 90 *  Page_Count)) / 128.0/1024.0),
       SavingsGB100 = CONVERT(INT, (Page_Count - (avg_page_space_used_in_percent / 100 * Page_Count)) / 128.0/1024.0),
	   *
from dba.dbo.fragstats 
Order by SavingsGB090 desc

