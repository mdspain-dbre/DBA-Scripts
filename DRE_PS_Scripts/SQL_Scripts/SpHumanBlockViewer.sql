select * from dbo.fragstats
where [Schema] = 'Meta'
order by [index]
go 


sp_whoisactive 


EXEC dbo.sp_HumanEventsBlockViewer
    @session_name = N'blocked_process';

/*
Lead Blocker
Meta.Partitions.Save 

BLocked 
Meta.HubPartitionMap_GetByPartitionID

Lead 
Meta.HubPartitionMap_GetByPartitionID
Blocking
Meta.HubPartitionMap_GetByPartitionID

Wait Resource Partitions table 

*/