USE Harmony
GO

ALTER DATABASE [Harmony] SET DELAYED_DURABILITY = FORCED WITH NO_WAIT

GO
 
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ph')
BEGIN

    EXEC ('CREATE SCHEMA ph');
END;
ELSE
BEGIN
    Raiserror ('Schema PH exists',0,1) with nowait;
END;

GO

if exists(select 1 from sys.views where name = 'FileGroupDetail')
	BEGIN 
	DROP VIEW ph.FileGroupDetail
	END

if exists(select 1 from sys.views where name = 'ObjectDetail')
	BEGIN 
	DROP VIEW ph.ObjectDetail
	END

Raiserror ('Creating [ph].[FileGroupDetail] ',0,1) with nowait
Raiserror ('Creating [ph].[ObjectDetail] ',0,1) with nowait

GO

CREATE or Alter VIEW [ph].[FileGroupDetail]
AS
SELECT  pf.name AS pf_name ,
        ps.name AS partition_scheme_name ,
        p.partition_number ,
        ds.name AS partition_filegroup ,
        pf.type_desc AS pf_type_desc ,
        pf.fanout AS pf_fanout ,
        pf.boundary_value_on_right ,
        OBJECT_NAME(si.object_id) AS object_name ,
        rv.value AS range_value ,
        SUM(CASE WHEN si.index_id IN ( 1, 0 ) THEN p.rows
                    ELSE 0
            END) AS num_rows ,
        SUM(dbps.reserved_page_count) * 8 / 1024. AS reserved_mb_all_indexes ,
        SUM(CASE ISNULL(si.index_id, 0)
                WHEN 0 THEN 0
                ELSE 1
            END) AS num_indexes
FROM    sys.destination_data_spaces AS dds
        JOIN sys.data_spaces AS ds ON dds.data_space_id = ds.data_space_id
        JOIN sys.partition_schemes AS ps ON dds.partition_scheme_id = ps.data_space_id
        JOIN sys.partition_functions AS pf ON ps.function_id = pf.function_id
        LEFT JOIN sys.partition_range_values AS rv ON pf.function_id = rv.function_id
                                                        AND dds.destination_id = CASE pf.boundary_value_on_right
                                                                                    WHEN 0 THEN rv.boundary_id
                                                                                    ELSE rv.boundary_id + 1
                                                                                END
        LEFT JOIN sys.indexes AS si ON dds.partition_scheme_id = si.data_space_id
        LEFT JOIN sys.partitions AS p ON si.object_id = p.object_id
                                            AND si.index_id = p.index_id
                                            AND dds.destination_id = p.partition_number
        LEFT JOIN sys.dm_db_partition_stats AS dbps ON p.object_id = dbps.object_id
                                                        AND p.partition_id = dbps.partition_id
GROUP BY ds.name ,
        p.partition_number ,
        pf.name ,
        pf.type_desc ,
        pf.fanout ,
        pf.boundary_value_on_right ,
        ps.name ,
        si.object_id ,
        rv.value;
GO
Raiserror ('Creating [ph].[ObjectDetail] ',0,1) with nowait
GO
--Create a view to see partition information by object
CREATE VIEW ph.ObjectDetail	
AS
SELECT  SCHEMA_NAME(so.schema_id) AS schema_name ,
        OBJECT_NAME(p.object_id) AS object_name ,
        p.partition_number ,
        p.data_compression_desc ,
        dbps.row_count ,
        dbps.reserved_page_count * 8 / 1024. AS reserved_mb ,
        si.index_id ,
        CASE WHEN si.index_id = 0 THEN '(heap!)'
                ELSE si.name
        END AS index_name ,
        si.is_unique ,
        si.data_space_id ,
        mappedto.name AS mapped_to_name ,
        mappedto.type_desc AS mapped_to_type_desc ,
        partitionds.name AS partition_filegroup ,
        pf.name AS pf_name ,
        pf.type_desc AS pf_type_desc ,
        pf.fanout AS pf_fanout ,
        pf.boundary_value_on_right ,
        ps.name AS partition_scheme_name ,
        rv.value AS range_value
FROM    sys.partitions p
JOIN    sys.objects so
        ON p.object_id = so.object_id
            AND so.is_ms_shipped = 0
LEFT JOIN sys.dm_db_partition_stats AS dbps
        ON p.object_id = dbps.object_id
            AND p.partition_id = dbps.partition_id
JOIN    sys.indexes si
        ON p.object_id = si.object_id
            AND p.index_id = si.index_id
LEFT JOIN sys.data_spaces mappedto
        ON si.data_space_id = mappedto.data_space_id
LEFT JOIN sys.destination_data_spaces dds
        ON si.data_space_id = dds.partition_scheme_id
            AND p.partition_number = dds.destination_id
LEFT JOIN sys.data_spaces partitionds
        ON dds.data_space_id = partitionds.data_space_id
LEFT JOIN sys.partition_schemes AS ps
        ON dds.partition_scheme_id = ps.data_space_id
LEFT JOIN sys.partition_functions AS pf
        ON ps.function_id = pf.function_id
LEFT JOIN sys.partition_range_values AS rv
        ON pf.function_id = rv.function_id
            AND dds.destination_id = CASE pf.boundary_value_on_right
                                        WHEN 0 THEN rv.boundary_id
                                        ELSE rv.boundary_id + 1
                                    END
GO

GO
--Drop new partitioned object if it exists 
Raiserror ('Dropping paritioned table if exists',0,1) with nowait

	Drop Table if exists [dbo].[Links_IsValid_Partitioned2]

Go
---Drop Partition Scheme and Functions
Raiserror ('Dropping parition scheme and function if exists',0,1) with nowait

IF EXISTS(
SELECT 1 FROM sys.partition_schemes
WHERE name = 'LinksIsValid2_PS')
BEGIN 

	DROP PARTITION SCHEME LinksIsValid2_PS

END 

IF EXISTS(
SELECT 1 FROM sys.partition_functions
WHERE name = 'LinksIsValid2_PF')
BEGIN 

	DROP  PARTITION FUNCTION LinksIsValid2_PF

END 

GO
 
Raiserror ('Creating partition function',0,1) with nowait

CREATE PARTITION FUNCTION LinksIsValid2_PF(bit) AS RANGE RIGHT FOR VALUES (0,1)

GO 

Raiserror ('Creating parition scheme',0,1) with nowait

CREATE PARTITION SCHEME LinksIsValid2_PS
	AS PARTITION LinksIsValid2_PF
	ALL TO ([Primary]) 

GO

Raiserror ('Creating new partitioned table',0,1) with nowait


GO
USE [Harmony]
GO

CREATE TABLE [dbo].[Links_IsValid_Partitioned2](
	[HubAId] [bigint] NOT NULL,
	[IsValid] [bit] NOT NULL,
	[LinkContextId] [int] NOT NULL,
	[HubBId] [bigint] NOT NULL,
	[EffectiveDate] [datetime2](2) NOT NULL,
	INDEX CCI_Links_IsValid_Partitioned2 Clustered Columnstore 
) ON [LinksIsValid2_PS]([IsValid])
GO



/***********************
truncate table [dbo].[Links_IsValid_Partitioned2];
drop table [dbo].[Links_Partitioned2];

Create Nonclustered Index NCIX_IsValid on dbo.Links(IsValid)
where IsValid = 1
WITH (DATA_COMPRESSION = PAGE)

Truncate Table [dbo].[Links_IsValid_Partitioned2] 

select * , cast(FORMAT(num_rows, 'N0') as varchar(20)) as FormattedRows
from [ph].[FileGroupDetail] 
	where pf_name =  'LinksIsValid2_PF'
	and (num_rows is not null and reserved_mb_all_indexes is not null)


	(4426992272, 46, 4260019992, 1)

Select * from [dbo].[Links_IsValid_Partitioned2]
where HubAid = 4426992272 and LinkContextID = 46 and HubBid = 4260019992 and isValid = 1

   57,100,000-->Sep 22 2025  7:48PM
   74,953,264-->Sep 22 2025  7:50PM
  218,300,000-->Sep 22 2025  8:13PM
1,997,005,903-->Sep 23 2025 12:08AM
2,002,902,804-->Sep 23 2025 12:09AM
2,122,256,015-->Sep 23 2025 12:25AM
2,380,200,000-->Sep 23 2025 12:58AM
2,818,600,000-->Sep 23 2025  2:00AM


281,322,936-->Sep 23 2025  2:49AM

 (2985567891, 7, 4399845064, 1).

  select top(10) * from dbo.Links_IsValid_Partitioned2
 where HubAId = 2985567891 and HubBId = 4399845064 --and IsValid =1

   select top(10) * from dbo.Links
 where HubAId = 2985567891 and HubBId = 4399845064 --and IsValid =1

 truncate table dbo.Links_IsValid_Partitioned2
************************/




--/*************************************************************
GO
Raiserror ('Loading Test Data',0,1) with nowait;
GO

Set NOCOUNT ON;





/*************************************************
*************************************************
*************************************************
CREATE NONCLUSTERED INDEX NCIX_Links_IsValid
ON dbo.Links (IsValid)
WHERE IsValid = 1  
WITH (DATA_COMPRESSION = PAGE)

Insert [dbo].[Links_IsValid_Partitioned]
Select top(1)* from [dbo].[Links] with (NOLOCK)
	WHERE isValid = 1

--35 minutes to create

select count(*), datepart from dbo.Links
WHERE IsValid =  1  

truncate table [dbo].[Links_IsValid_Partitioned]
Truncate Table [Meta].[MatchScores_Direct_Partitioned] With(Partitions(3))

*************************************************
*************************************************
************************************************************/
