# Create a Windows Server VM in Azure with content-services tags

##az login 

$resourceGroup   = 'content-services-documentdb'
$vmName           = 'cs-win-vm-01'
$location         = 'westus2'
$adminUser        = 'dreadmin'
$adminPassword    = 'v4W%sA4i!nm@aSZz'
$image            = 'Win2022Datacenter'
$size             = 'Standard_D2s_v3'

# SAS token from blob storage (for azcopy or custom script use)
##$sasToken = 'sv=2024-11-04&ss=bfqt&srt=sco&sp=rwdlacupiytfx&se=2028-03-18T03:41:05Z&st=2026-03-17T19:26:05Z&spr=https&sig=5HCDN97oD0rM%2F86KqZrNVuA7IJyNPY%2BKKjPBNcudquw%3D'

# Tags matching content-services convention
$tags = @(
    'apmid=APM0000000'
    'applicationname=content-services'
    'cost-center=2650'
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

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Assert-AzSuccess {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "az CLI failed at: $Step (exit code $LASTEXITCODE)"
    }
}

try {

Write-Information "Creating NSG with Tags"
# 1. Create NSG with tags
az network nsg create `
    --resource-group $resourceGroup `
    --name "$vmName-nsg" `
    --location $location `
    --tags $tags
Assert-AzSuccess "Create NSG"

Write-Information "Adding RDP rule to NSG"  
# 2. Add RDP rule to NSG
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name "$vmName-nsg" `
    --name AllowRDP `
    --priority 1000 `
    --destination-port-ranges 3389 `
    --access Allow `
    --protocol Tcp `
    --direction Inbound
Assert-AzSuccess "Create NSG Rule"

# 3. Use existing VNet: dre-vnet1 / subnet1 (in a different resource group)
$vnetRG     = 'DRE-sandbox-network-rg'
$vnetName   = 'dre-vnet1'
$subnetName = 'dre-vnet1-subnet1'

Write-Information "Retrieving subnet ID for VNet '$vnetName' in RG '$vnetRG'"
# Get the full subnet resource ID (required when VNet is in a different RG)
$subnetId = az network vnet subnet show `
    --resource-group $vnetRG `
    --vnet-name $vnetName `
    --name $subnetName `
    --query id -o tsv
Assert-AzSuccess "Get Subnet ID"

Write-Information "Subnet ID: $subnetId"
# 4. Create NIC with tags (no public IP - disallowed by policy)
az network nic create `
    --resource-group $resourceGroup `
    --name "$vmName-nic" `
    --location $location `
    --subnet $subnetId `
    --network-security-group "$vmName-nsg" `
    --tags $tags
Assert-AzSuccess "Create NIC"

Write-Information "Creating VM '$vmName' with pre-created NIC and tags"    
# 5. Create VM referencing the pre-created NIC (no public IP)
az vm create `
    --resource-group $resourceGroup `
    --name $vmName `
    --location $location `
    --image $image `
    --size $size `
    --admin-username $adminUser `
    --admin-password $adminPassword `
    --nics "$vmName-nic" `
    --data-disk-sizes-gb 1024 `
    --security-type TrustedLaunch `
    --tags $tags
Assert-AzSuccess "Create VM"

Write-Information "Tagging OS and data disks for VM '$vmName'"    
# 6. Tag the OS disk
$osDiskId = az vm show -g $resourceGroup -n $vmName --query "storageProfile.osDisk.managedDisk.id" -o tsv
Assert-AzSuccess "Get OS Disk ID"
az resource tag --ids $osDiskId --tags $tags
Assert-AzSuccess "Tag OS Disk"

# 7. Tag the data disk
$dataDiskId = az vm show -g $resourceGroup -n $vmName --query "storageProfile.dataDisks[0].managedDisk.id" -o tsv
Assert-AzSuccess "Get Data Disk ID"
az resource tag --ids $dataDiskId --tags $tags
Assert-AzSuccess "Tag Data Disk"

Write-Host "`nVM '$vmName' created. Retrieve the private IP with:"
Write-Host "az vm show -g $resourceGroup -n $vmName -d --query privateIps -o tsv"

} catch {
    Write-Host "`n*** ERROR ***" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nFailed at step. Partial resources may need cleanup:" -ForegroundColor Yellow
    Write-Host "  az network nic delete -g $resourceGroup -n $vmName-nic" -ForegroundColor Yellow
    Write-Host "  az network nsg delete -g $resourceGroup -n $vmName-nsg" -ForegroundColor Yellow
    Write-Host "  az vm delete -g $resourceGroup -n $vmName --yes" -ForegroundColor Yellow
}


# Bastion tunnel (requires Standard SKU):
# az network bastion tunnel --name drebastion -g "DRE-sandbox-network-rg" --target-resource-id $(az vm show -g content-services-documentdb -n cs-win-vm-01 --query id -o tsv) --resource-port 3389 --port 33389
# Then RDP to localhost:33389
#or Standard SKU):
# Azure Portal > VM > Connect > Bastion

az network bastion tunnel --name drebastion -g "DRE-sandbox-network-rg" --target-resource-id $(az vm show -g content-services-documentdb -n cs-win-vm-01 --query id -o tsv) --resource-port 3389 --port 33389