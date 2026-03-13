SELECT 
    DatabaseName, 
    CAST(SUM(FileSizeGB) AS DECIMAL(18,2)) AS TotalSizeGB,
    CollectionTime
INTO #DBGrowth
FROM Collector.ContentServicesDBGrowth
WHERE FileType = 'Rows'
GROUP BY CollectionTime, DatabaseName;

SELECT 
    DatabaseName,
    CollectionTime,
    TotalSizeGB,
    LAG(TotalSizeGB) OVER (PARTITION BY DatabaseName ORDER BY CollectionTime) AS PrevSizeGB,
    ISNULL(TotalSizeGB - LAG(TotalSizeGB) OVER (PARTITION BY DatabaseName ORDER BY CollectionTime), 0) AS GrowthGB
FROM #DBGrowth
ORDER BY DatabaseName, CollectionTime;

DROP TABLE #DBGrowth;


SELECT 
    DatabaseName, 
    CAST(SUM(UsedSpaceGB) AS DECIMAL(18,2)) AS TotalUsedSpaceGB,
    CollectionTime
INTO #DBUsedSapceGrowth
FROM Collector.ContentServicesDBGrowth
WHERE FileType = 'Rows'
GROUP BY CollectionTime, DatabaseName;

SELECT 
    DatabaseName,
    CollectionTime,
    TotalUsedSpaceGB,
    LAG(TotalUsedSpaceGB) OVER (PARTITION BY DatabaseName ORDER BY CollectionTime) AS PrevTotalUsedSpaceGB,
    ISNULL(TotalUsedSpaceGB - LAG(TotalUsedSpaceGB) OVER (PARTITION BY DatabaseName ORDER BY CollectionTime), 0) AS UsedSpaceGrowthGB
FROM #DBUsedSapceGrowth
ORDER BY DatabaseName, CollectionTime;

DROP TABLE #DBUsedSapceGrowth;




select * 
from Collector.ContentServicesDBGrowth


SELECT 
    ServerName,
    DatabaseName,
    FileName,
    FileType,
    CollectionTime,
    CAST(FreeSpacePct AS DECIMAL(10,2)) AS FreeSpacePct,
    CAST(LAG(FreeSpacePct) OVER (PARTITION BY ServerName, DatabaseName, FileName ORDER BY CollectionTime) AS DECIMAL(10,2)) AS PrevFreeSpacePct,
    CAST(FreeSpacePct - ISNULL(LAG(FreeSpacePct) OVER (PARTITION BY ServerName, DatabaseName, FileName ORDER BY CollectionTime), FreeSpacePct) AS DECIMAL(10,2)) AS FreeSpacePctChange
FROM Collector.ContentServicesDBGrowth
where FileType = 'rows' and DatabaseName <> 'tempdb'
ORDER BY ServerName, DatabaseName, FileName, CollectionTime;

SELECT 
    ServerName,
    DatabaseName,
    FileName,
    FileType,
    CollectionTime,
    CAST(FreeSpacePct AS DECIMAL(10,2)) AS FreeSpacePct,
    ISNULL(CAST(LAG(FreeSpacePct) OVER (PARTITION BY ServerName, DatabaseName, FileName ORDER BY CollectionTime) AS VARCHAR(20)), '--') AS PrevFreeSpacePct,
    CAST(FreeSpacePct - ISNULL(LAG(FreeSpacePct) OVER (PARTITION BY ServerName, DatabaseName, FileName ORDER BY CollectionTime), FreeSpacePct) AS DECIMAL(10,2)) AS FreeSpacePctChange
FROM Collector.ContentServicesDBGrowth
where FileType = 'rows' and DatabaseName not in ('tempdb','master','model','msdb')
ORDER BY ServerName, DatabaseName, FileName, CollectionTime;
