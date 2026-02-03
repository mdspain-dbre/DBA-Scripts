Invoke-WebRequest  -Uri https://github.com/adbertram/MySQL/archive/master.zip -OutFile  'C:\MySQL.zip'

$modulesFolder =  'C:\Program Files\WindowsPowerShell\Modules'

  Expand-Archive -Path  C:\MySql.zip -DestinationPath $modulesFolder

  Rename-Item -Path  "$modulesFolder\MySql-master" -NewName MySQL

  $dbCred =  Get-Credential

  Connect-MySqlServer  -Credential $dbcred -ComputerName 'MYSQLSERVER' -Database SynergyLogistics


  Invoke-MySqlQuery  -Query 'SELECT * FROM Users'