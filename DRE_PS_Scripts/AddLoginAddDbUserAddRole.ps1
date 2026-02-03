$user = "vizio"
##$password = read-host "Enter Password" | ConvertTo-SecureString -AsPlainText -Force

$password = 'C#3&da&V#KSci8S$1Iy8LI*$w&3wJMv9'     | ConvertTo-SecureString -AsPlainText -Force 



$credential = New-Object System.Management.Automation.PSCredential ($user, $password)

$SQLInstance = "vueuserprod1.cha2gmuppdx1.us-west-2.rds.amazonaws.com"

##Create Login NikitaKramar_RW with Password = 'FaU&ZI$cEl%05lFz'

$securePassword = 'FaU&ZI$cEl%05lFz' | ConvertTo-SecureString -AsPlainText -Force 

New-DbaLogin -SqlInstance $SQLInstance -Login "NikitaKramar_RW"  -SecurePassword $securePassword -SqlCredential $credential

$DBs = Get-DbaDatabase -SqlInstance $SQLInstance -ExcludeDatabase rdsadmin -ExcludeSystem -SqlCredential $credential


foreach($DB in $DBs)
    {

write-host Adding new user to $($DB.Name) -ForegroundColor red 
 
New-DbaDbUser -SqlInstance $SQLInstance -Database $($DB.Name) -Login "NikitaKramar_RW" -SqlCredential $credential -Force -Confirm:$False

write-host Adding new user to RW roles -ForegroundColor yellow

Add-DbaDbRoleMember -SqlInstance $SQLInstance -Database $($DB.Name)  -Role db_datareader -Member "NikitaKramar_RW" -SqlCredential $credential -Confirm:$False
Add-DbaDbRoleMember -SqlInstance $SQLInstance -Database $($DB.Name)  -Role db_datawriter -Member "NikitaKramar_RW" -SqlCredential $credential -Confirm:$False

}