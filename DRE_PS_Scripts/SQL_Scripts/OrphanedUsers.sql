IF OBJECT_ID('tempdb..#orphans') is NOT NULL
DROP TABLE #orphans 
GO
--create temp table to store oprhaned users 


CREATE TABLE #orphans
(dbname VARCHAR(50),
db_user VARCHAR(50))
go


--loop through all DBs searching for user in sys.database_principals whose SID has no match in sys.server_principals


EXEC sp_msforeachdb 
'USE [?]; insert into #orphans(dbname, db_user)
SELECT ''[?]'' AS DBname, dp.name from sys.database_principals dp
where dp.type <>''r'' and dp.name <> ''guest'' and 
    dp.sid not in 
(    
        select sid from sys.server_principals
) '
go
--generate orphaned users syntax
-- copy  orphaned_user_fix column and run


SELECT  * ,
        'USE ' + #orphans.DBNAME + ';' + ' exec sp_change_users_login '
        + '''update_one''' + ',' + '''' + #orphans.db_user + '''' + ',' + ''''
        + #orphans.db_user + '''' AS orphaned_user_fix
FROM    #orphans 
JOIN sys.syslogins l  ON #orphans.db_user = l.name   -- will return only accounts the are being used.  

