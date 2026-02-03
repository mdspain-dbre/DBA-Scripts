##import-module dbatools 

$instance = "sql-stage-smartcast.cbt1o41fyqmy.us-west-2.rds.amazonaws.com"
 <#
 SywxLz5&rwNE2lla

  $creds = get-credential -UserName admin 
 #>


 $params = @{
 SqlInstance = $instance 
 Destination = $instance
 ##SqlCredential = $creds
 ##DestinationSqlCredential = $creds 
 Database = 'Harmony'
 DestinationDatabase = 'Harmony'
 Table = '[dbo].[Links]'
 DestinationTable = '[dbo].[Links_IsValid_Partitioned2]'
 KeepIdentity = $true
 KeepNulls = $true
 Truncate = $true
 BatchSize = 200000
 Query = "Select * from dbo.links with (NOLOCK)  where isvalid = 1 "

 }

Copy-DbaDbTableData @params 

##Start Time 12:50 AM
