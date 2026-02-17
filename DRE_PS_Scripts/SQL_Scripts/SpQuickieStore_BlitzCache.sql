EXEC dbo.sp_HumanEventsBlockViewer @help = 1

Exec sp_QuickieStore @database_name = 'Harmony' ,@procedure_schema ='Meta', @procedure_name = 'Partitions_Save', @expert_mode =1


Execute Sp_BlitzCache @DatabaseName = 'Harmony', @StoredProcName = 'Partitions_Save', @HideSummary =1, @ExpertMode = 1


