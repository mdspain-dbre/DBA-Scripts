/*
===============================================================================
HARMONY INDEX FRAGMENTATION COLLECTION
===============================================================================
Purpose:    Collects index fragmentation statistics for all indexes in the 
            Harmony database using sys.dm_db_index_physical_stats DMV.

Description:
            This script performs a detailed analysis of index fragmentation 
            and stores the results in DBA.dbo.FragStats table. The data is 
            used by IndexMaint.HarmonyIndexMaint to determine which indexes 
            need rebuilding based on page density thresholds.

            Uses 'Detailed' mode which provides the most comprehensive stats
            including page density (avg_page_space_used_in_percent).

Target:     Harmony database
Output:     DBA.dbo.FragStats table

Notes:
            - Truncates existing data before each collection
            - 'Detailed' mode can be resource intensive on large databases
            - CollectionTime tracks when stats were gathered

Author:     Michael DSpain
===============================================================================
*/

USE Harmony
GO

-- Clear previous fragmentation data to ensure fresh collection
TRUNCATE TABLE dba.dbo.fragstats

-- Capture collection timestamp for tracking
DECLARE @CollectionTime datetime
SET @CollectionTime = GETDATE()

-- Collect fragmentation stats using sys.dm_db_index_physical_stats
-- 'Detailed' mode provides avg_page_space_used_in_percent (page density)
INSERT INTO dba.dbo.fragstats
SELECT 
    S.name AS 'Schema',              -- Schema name for the table
    T.name AS 'Table',               -- Table name
    I.name AS 'Index',               -- Index name (NULL for heaps)
    DDIPS.*,                         -- All DMV columns (fragmentation %, page count, etc.)
    @CollectionTime                  -- When this data was collected
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'Detailed') AS DDIPS
INNER JOIN sys.tables T 
    ON T.object_id = DDIPS.object_id
INNER JOIN sys.schemas S 
    ON T.schema_id = S.schema_id
INNER JOIN sys.indexes I 
    ON I.object_id = DDIPS.object_id
    AND DDIPS.index_id = I.index_id
WHERE DDIPS.database_id = DB_ID()    -- Current database only

