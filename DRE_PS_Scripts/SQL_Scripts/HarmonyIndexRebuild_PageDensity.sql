Set statistics profile on
Set NoCount on

Drop Table If Exists #HarmonyIndexes;
Declare @print bit = 0

select [schema],
       [table],
       [index],
       AVG(avg_page_space_used_in_percent) as AVG_PageDensity,
	   AVG(Page_count) as AVG_PageCount,
       Case
           when Index_id > 0 then
               'Alter Index ' + [Index] + ' On ' + [Schema] + '.' + [Table]
               + ' Rebuild With (Online = Off,FillFactor = 95, MaxDop = 32);'
           Else
               'Alter Table ' + [Schema] + '.' + [Table] + ' Rebuild with (Online = Off,FillFactor = 95, MaxDop = 32);'
       end as IndexStmnt
Into #HarmonyIndexes
from dba.dbo.fragstats
where CollectionTime = (select max(CollectionTime) from dba.dbo.fragstats)
Group By [Schema],[Table],[Index], [index_id]


/*
select * from #HarmonyIndexes
where AVG_PageDensity < 90 and AVG_PageCount > 1000 and [table] <> 'MatchScores_Direct'
order  by [Schema] desc

Select [table],[Index], avg(avg_fragmentation_in_Percent) ,CollectionTime
from dba.dbo.fragstats
where --CollectionTime = (select max(CollectionTime) from dba.dbo.fragstats) 
--and 
[schema] = 'Meta' and [Table] = 'Partitions'
Group by  [table],[Index],CollectionTime
Order by CollectionTime desc 
*/
DECLARE @Indexcount int
Set @Indexcount =
(
    Select count(*) from #HarmonyIndexes where AVG_PageDensity < 90 and AVG_PageCount > 1000 and [table] <> 'MatchScores_Direct'


)

DECLARE @IndexIterator int = 1


DECLARE CS CURSOR FORWARD_ONLY STATIC FOR
Select [Schema],
       [Table],
       [Index],
       AVG_PageCount,
       AVG_PageDensity,
       INdexStmnt
from #HarmonyIndexes
where AVG_PageDensity < 90 and AVG_PageCount > 1000 and [table] <> 'MatchScores_Direct'
order by AVG_PageCount 

-- Declare variables to hold the values
DECLARE @SchemaName varchar(15);
DECLARE @TableName varchar(60);
DECLARE @IndexStmnt varchar(500);
DECLARE @pagecount int;
DECLARE @pagedensity float

-- Open the cursor
OPEN CS;

-- Fetch the first row
FETCH NEXT FROM CS
INTO @SchemaName,
     @TableName,
     @IndexStmnt,
     @pagecount,
     @pagedensity,
     @INdexStmnt;

-- Loop through the rows
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Do something with the data
    Declare @Indexcountmessage varchar(100)
    Set @Indexcountmessage = cast(@IndexIterator as varchar(3)) + '..of..' + Cast(@Indexcount as varchar(10))


    Declare @IndexMessage varchar(600)
    Set @IndexMessage
        = 'Working on--->' + QuoteName(@SchemaName) + '.' + QuoteName(@TableName) + char(13) + @IndexStmnt + char(13)
          + 'page count.. ' + cast(@pagecount as varchar(20)) + char(13) + 'page density.. '
          + cast(@pagedensity as varchar(20)) + char(13) + '/**************************/'


    if @print = 0
    Begin
        RAISERROR(@Indexcountmessage, 0, 1) WITH NOWAIT
        RAISERROR(@IndexMessage, 0, 1) WITH NOWAIT
		Execute (@IndexStmnt)
    end

    if @print = 1
    Begin
        RAISERROR(@Indexcountmessage, 0, 1) WITH NOWAIT
        RAISERROR(@IndexMessage, 0, 1) WITH NOWAIT
    end


    Set @IndexIterator = @IndexIterator + 1

    -- Fetch the next row
    FETCH NEXT FROM CS
    INTO @SchemaName,
         @TableName,
         @IndexStmnt,
         @pagecount,
         @pagedensity,
         @INdexStmnt;
END;

-- Clean up
CLOSE CS;
DEALLOCATE CS;

