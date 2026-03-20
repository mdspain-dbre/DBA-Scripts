# Create a Windows Server VM in Azure with content-services tags

az login 

$resourceGroup   = 'content-services-documentdb'
$vmName           = 'cs-windows-vm-01'
$location         = 'westus'
$adminUser        = 'contentservicesazureadmin'
$adminPassword    = 'v4W%sA4i!nm@aSZz'
$image            = 'Win2022Datacenter'
$size             = 'Standard_D2s_v3'

# SAS token from blob storage (for azcopy or custom script use)
$sasToken = 'sv=2024-11-04&ss=bfqt&srt=sco&sp=rwdlacupiytfx&se=2028-03-18T03:41:05Z&st=2026-03-17T19:26:05Z&spr=https&sig=5HCDN97oD0rM%2F86KqZrNVuA7IJyNPY%2BKKjPBNcudquw%3D'

# Tags matching content-services convention
$tags = @(
    'apmid=APM0000000'
    'applicationname=content-services'
    'cost-center=2650'ß
    'created-by=michael dspain'
    'environment=dev'
    'function=content-services'
    "name=$vmName"
    'notificationdistlist=cpie-dre@vizio.com'
    'owner=cpie-dre'
    'repo=CognitiveNetworks/evergreen-inscape-iac'
    'service=content-services'
    'ssp=00000000'
    'trproductid=6055'
)

# Create the VM with a 500GB data disk
az vm create `
    --resource-group $resourceGroup `
    --name $vmName `
    --location $location `
    --image $image `
    --size $size `
    --admin-username $adminUser `
    --admin-password $adminPassword `
    --tags $tags `
    --public-ip-sku Standard `
    --nsg-rule RDP `
    --data-disk-sizes-gb 500

# Open RDP port (if not already opened by --nsg-rule)
az vm open-port `
    --resource-group $resourceGroup `
    --name $vmName `
    --port 3389

Write-Host "`nVM '$vmName' created. Retrieve the public IP with:"
Write-Host "az vm show -g $resourceGroup -n $vmName -d --query publicIps -o tsv"
