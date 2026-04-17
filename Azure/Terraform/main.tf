# =============================================================================
# TERRAFORM CONFIGURATION
# =============================================================================
# This block tells Terraform which providers (plugins) are needed.
# Providers are how Terraform talks to cloud APIs — in this case, Azure.
# "~> 4.0" means any version >= 4.0 and < 5.0 (pessimistic constraint).
# =============================================================================
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"   # Download from HashiCorp's registry
      version = "~> 4.0"              # Pin to major version 4.x
    }
    azapi = {
      source  = "azure/azapi"         # For resources not yet in azurerm
      version = "~> 2.0"
    }
  }
}

# =============================================================================
# AZURE PROVIDER
# =============================================================================
# Configures how Terraform authenticates and interacts with Azure.
# - "features {}" is required by azurerm even if empty (provider won't init without it).
# - subscription_id targets a specific Azure subscription so resources are
#   created in the right billing/organizational context.
# - Authentication uses whatever method is available (az CLI login, env vars,
#   managed identity, or service principal).
# =============================================================================
provider "azurerm" {
  features {}
  subscription_id = "148f67ee-68bc-429e-916b-4ca8568f3c6d"
}

# =============================================================================
# VARIABLES
# =============================================================================
# Variables let you parameterize the config so values aren't hard-coded.
# Defaults are provided for most variables, but they can be overridden at
# runtime via:
#   - CLI flags:        terraform plan -var="vm_name=my-vm"
#   - .tfvars file:     terraform plan -var-file="prod.tfvars"
#   - Environment vars: TF_VAR_vm_name="my-vm"
# =============================================================================

# The name used for the VM and as a prefix for related resources (NIC, NSG, disk).
variable "vm_name" {
  default = "cs-win-vm-01"
}

# Azure region where all resources will be deployed.
# See full list: https://azure.microsoft.com/en-us/explore/global-infrastructure/geographies
variable "location" {
  default = "westus2"
}

# The existing resource group that will contain the VM and its resources.
# This resource group must already exist in Azure — Terraform will NOT create it.
variable "resource_group_name" {
  default = "content-services-documentdb"
}

# Local admin username for RDP access to the Windows VM.
variable "admin_username" {
  default = "dreadmin"
}

# Local admin password for the VM. Marked "sensitive" so Terraform won't
# display it in plan output or logs. Since there's no default, you MUST
# supply it at runtime (e.g., -var="admin_password=YourP@ssw0rd!").
variable "admin_password" {
  sensitive = true
}

# SQL Managed Instance admin password. Marked "sensitive" so Terraform won't
# display it in plan output or logs. Must meet Azure complexity requirements:
# 16+ chars, upper, lower, number, special character.
variable "sqlmi_admin_password" {
  sensitive = true
}

# Azure VM size (SKU) — determines CPU, RAM, and disk performance.
# Standard_D2s_v3 = 2 vCPUs, 8 GB RAM, supports Premium SSD.
# Browse sizes: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes
variable "vm_size" {
  default = "Standard_D2s_v3"
}

# The resource group that owns the existing VNet we want to attach to.
# This is separate from the VM's resource group because networking is
# often managed by a different team/subscription.
variable "vnet_resource_group" {
  default = "DRE-sandbox-network-rg"
}

# The name of the existing Virtual Network (VNet) to join.
variable "vnet_name" {
  default = "dre-vnet1"
}

# The specific subnet within the VNet where the VM's NIC will get an IP.
variable "subnet_name" {
  default = "dre-vnet1-subnet1"
}

# =============================================================================
# LOCAL VALUES (Computed/Reusable Values)
# =============================================================================
# Locals let you define values once and reuse them across multiple resources.
# Here we define a standard set of tags that get applied to every resource
# for cost tracking, ownership, and organizational policies.
# =============================================================================
locals {
  tags = {
    apmid                = "APM0000000"
    applicationname      = "content-services"
    "cost-center"        = "2650"                                # Used for billing/chargeback
    "created-by"         = "michael dspain"
    environment          = "dev"
    function             = "content-services"
    name                 = var.vm_name                           # Dynamic — uses the VM name variable
    notificationdistlist = "cpie-dre@vizio.com"
    owner                = "cpie-dre"
    repo                 = "CognitiveNetworks/evergreen-inscape-iac"
    service              = "content-services"
    ssp                  = "00000000"
    trproductid          = "6055"
  }
}

# =============================================================================
# DATA SOURCE: Look Up an Existing Subnet
# =============================================================================
# A "data" block reads information about resources that already exist in Azure
# (as opposed to "resource" blocks which create new things).
# We need the subnet's ID to attach our NIC to it. The subnet lives in a
# different resource group (DRE-sandbox-network-rg), so we reference it here.
# =============================================================================
data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group
}

# =============================================================================
# NETWORK SECURITY GROUP (NSG)
# =============================================================================
# An NSG acts as a virtual firewall for the VM. It contains security rules
# that allow or deny inbound/outbound network traffic.
#
# This NSG allows inbound RDP (port 3389) from any source. In production,
# you'd want to restrict source_address_prefix to specific IP ranges
# (e.g., your VPN CIDR) instead of "*" (anywhere).
#
# Rules are evaluated by priority (lower number = higher priority).
# Priority 1000 leaves room for higher-priority rules (100-999) if needed later.
# =============================================================================
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.vm_name}-nsg"    # Interpolation: "cs-win-vm-01-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

  security_rule {
    name                       = "AllowRDP"
    priority                   = 1000            # Lower number = evaluated first
    direction                  = "Inbound"       # Controls traffic coming IN to the VM
    access                     = "Allow"         # Allow (vs. Deny)
    protocol                   = "Tcp"           # RDP uses TCP
    source_port_range          = "*"             # Any source port (ephemeral)
    destination_port_range     = "3389"          # Standard RDP port
    source_address_prefix      = "*"             # Any source IP — restrict in production!
    destination_address_prefix = "*"             # Any destination (i.e., this VM's IP)
  }
}

# =============================================================================
# NETWORK INTERFACE (NIC)
# =============================================================================
# The NIC is the virtual network adapter that connects the VM to the subnet.
# Every Azure VM needs at least one NIC.
#
# - No public IP is assigned (org policy prohibits it — access via VPN/Bastion).
# - "Dynamic" means Azure picks an available private IP from the subnet's range.
#   The IP stays the same while the VM is running but may change after deallocation.
#   Use "Static" if you need a fixed private IP.
# - subnet_id references the data source above to attach to the existing subnet.
# =============================================================================
resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"     # "cs-win-vm-01-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = data.azurerm_subnet.subnet.id  # Links to the looked-up subnet
    private_ip_address_allocation = "Dynamic"                      # Azure auto-assigns a private IP
  }
}

# =============================================================================
# NSG <-> NIC ASSOCIATION
# =============================================================================
# This resource links the NSG to the NIC. Without this association, the
# firewall rules in the NSG would not apply to the VM's network traffic.
# NSGs can also be associated at the subnet level instead of (or in addition to)
# the NIC level.
# =============================================================================
resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# =============================================================================
# WINDOWS VIRTUAL MACHINE
# =============================================================================
# This is the main VM resource. Key details:
#
# - In azurerm v4.0+, TrustedLaunch with vTPM and Secure Boot is enabled by
#   default, so those arguments are no longer needed (they were removed).
#
# - OS Disk:
#     - "ReadWrite" caching improves performance for general workloads.
#     - "Premium_LRS" = SSD-backed, locally redundant storage (fast, single-region).
#       Other options: Standard_LRS (HDD), StandardSSD_LRS, Premium_ZRS.
#
# - Source Image:
#     - Specifies the marketplace image to use for the OS.
#     - "2022-datacenter-g2" = Windows Server 2022 Datacenter, Generation 2 VM
#       (Gen2 is required for TrustedLaunch and supports UEFI boot).
#     - "latest" always pulls the most recent patched version of this SKU.
#
# - The VM gets its network connectivity from the NIC created above.
# =============================================================================
resource "azurerm_windows_virtual_machine" "vm" {
  name                = var.vm_name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size               # Standard_D2s_v3 (2 vCPU, 8 GB RAM)
  admin_username      = var.admin_username
  admin_password      = var.admin_password         # Supplied at runtime (sensitive)
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.nic.id]  # Attach the NIC to this VM

  os_disk {
    caching              = "ReadWrite"             # Host caching for better read/write perf
    storage_account_type = "Premium_LRS"           # SSD-backed, locally redundant
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"           # Microsoft's official publisher
    offer     = "WindowsServer"                    # Product family
    sku       = "2022-datacenter-g2"               # Windows Server 2022, Gen2 (UEFI/TrustedLaunch)
    version   = "latest"                           # Always use the latest patched image
  }
}

# =============================================================================
# MANAGED DATA DISK (1 TB)
# =============================================================================
# A separate managed disk for data storage (MongoDB data files, backups, etc.).
# Keeping data on a separate disk from the OS has several benefits:
#   - You can resize/snapshot/detach the data disk independently of the OS.
#   - If you need to rebuild the VM, your data disk survives.
#   - Different caching/performance tiers can be applied per-disk.
#
# - "Empty" means create a blank, unformatted disk (you'll need to initialize
#   it inside Windows via Disk Management or PowerShell after first boot).
# - 1024 GB on Premium_LRS gives you the P30 performance tier:
#   ~5,000 IOPS and 200 MB/s throughput.
# =============================================================================
resource "azurerm_managed_disk" "data_disk" {
  name                 = "${var.vm_name}-datadisk-01"   # "cs-win-vm-01-datadisk-01"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"                         # New blank disk
  disk_size_gb         = 1024                            # 1 TB
  tags                 = local.tags
}

# =============================================================================
# DATA DISK ATTACHMENT
# =============================================================================
# This resource attaches the managed data disk to the VM. The disk and VM are
# created as separate resources so they can be managed independently.
#
# - LUN (Logical Unit Number) is the disk slot number inside the VM.
#   LUN 0 = first data disk. If you add more disks, use LUN 1, 2, etc.
# - "ReadWrite" caching is good for general workloads. For write-heavy
#   databases, consider "None" to avoid write cache overhead.
# =============================================================================
resource "azurerm_virtual_machine_data_disk_attachment" "data_disk_attach" {
  managed_disk_id    = azurerm_managed_disk.data_disk.id
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  lun                = 0                # First data disk slot
  caching            = "ReadWrite"
}

# =============================================================================
# AZURE DATABASE MIGRATION SERVICE v2 (SQL Migration Service)
# =============================================================================
# Creates a DMS v2 (SqlMigrationServices) instance. Unlike the classic DMS,
# v2 is a lightweight resource that does NOT deploy its own VNet-attached
# compute or NICs — avoiding the Azure tagging policy violation that blocked
# the classic DMS provisioning.
#
# - No SKU or subnet required — bring your own compute via a self-hosted
#   integration runtime (SHIR) installed on an existing VM.
# - Supports: SQL Server → Azure SQL DB, Azure SQL MI, SQL on Azure VMs.
# - The Microsoft.DataMigration resource provider must be registered.
# - Uses the azapi provider since azurerm has no native resource for this.
# =============================================================================
resource "azapi_resource" "dms_v2" {
  type      = "Microsoft.DataMigration/SqlMigrationServices@2022-03-30-preview"
  name      = "cs-dms-v2"
  location  = var.location
  parent_id = "/subscriptions/148f67ee-68bc-429e-916b-4ca8568f3c6d/resourceGroups/${var.resource_group_name}"
  tags      = local.tags
  body      = { properties = {} }
}

# =============================================================================
# OUTPUTS
# =============================================================================
# Outputs are printed after "terraform apply" completes and can be queried
# later with "terraform output". They're useful for:
#   - Displaying important info (IPs, resource IDs) after deployment.
#   - Passing values to other Terraform modules or scripts.
#
# The private IP is what you'll use to RDP into the VM (via VPN or Bastion).
# The VM ID is the full Azure resource ID, useful for CLI commands or scripts.
# =============================================================================
output "private_ip_address" {
  value = azurerm_network_interface.nic.private_ip_address
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.vm.id
}

# =============================================================================
# COSMOS DB ACCOUNT — MongoDB API (v7)
# =============================================================================
# Creates a new Cosmos DB account with the MongoDB API, matching the same
# configuration as contentservicecosmosdbtestv6:
#   - MongoDB server version 6.0
#   - Single region: West US (no zone redundancy)
#   - Automatic failover enabled
#   - Session consistency
#   - Periodic backup (every 4 hours, retained for 8 hours, geo-redundant)
#   - VNet filtering with the existing dre-vnet1-subnet1
#   - IP firewall rules for the same allowed addresses
#   - Capabilities: retryable writes, rate-limit bypass, 16MB doc support
#   - TLS 1.2 minimum
#   - No databases or collections are created (empty account)
# =============================================================================
resource "azurerm_cosmosdb_account" "cosmosdb_v7" {
  name                = "contentservicecosmosdbtestv7"
  location            = "westus"                          # Matches v6 (West US)
  resource_group_name = var.resource_group_name
  offer_type          = "Standard"
  kind                = "MongoDB"

  # MongoDB wire protocol version
  mongo_server_version = "6.0"

  # Consistency policy — Session is the default and most common for MongoDB API
  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }

  # Single geo-location: West US, failover priority 0 (primary)
  geo_location {
    location          = "westus"
    failover_priority = 0
    zone_redundant    = false
  }

  # Periodic backup: every 4 hours, retain 8 hours, geo-redundant storage
  backup {
    type                = "Periodic"
    interval_in_minutes = 240
    retention_in_hours  = 8
    storage_redundancy  = "Geo"
  }

  # Capabilities matching v6
  capabilities {
    name = "EnableMongo"
  }
  capabilities {
    name = "EnableMongoRetryableWrites"
  }
  capabilities {
    name = "DisableRateLimitingResponses"
  }
  capabilities {
    name = "EnableMongo16MBDocumentSupport"
  }

  # VNet firewall — restrict access to the existing subnet
  is_virtual_network_filter_enabled = true

  virtual_network_rule {
    id                                   = data.azurerm_subnet.subnet.id
    ignore_missing_vnet_service_endpoint = false
  }

  # IP firewall rules — same IPs allowed as v6
  ip_range_filter = ["50.224.132.171", "4.37.49.82", "20.99.222.211"]

  # Automatic failover (useful if you add regions later)
  automatic_failover_enabled = true

  # Public access and TLS
  public_network_access_enabled = true
  minimal_tls_version           = "Tls12"

  # Analytical storage disabled, free tier disabled
  analytical_storage_enabled = false
  free_tier_enabled          = false

  # Tags — same convention, updated name tag for v7
  tags = merge(local.tags, {
    name = "contentservicecosmosdbtestv7"
  })
}

# =============================================================================
# COSMOS DB v7 OUTPUTS
# =============================================================================
output "cosmosdb_v7_endpoint" {
  description = "The MongoDB connection endpoint for the v7 Cosmos DB account"
  value       = azurerm_cosmosdb_account.cosmosdb_v7.endpoint
}

output "cosmosdb_v7_id" {
  description = "The Azure resource ID of the v7 Cosmos DB account"
  value       = azurerm_cosmosdb_account.cosmosdb_v7.id
}

# =============================================================================
# AZURE SQL MANAGED INSTANCE — Business Critical
# =============================================================================
# Creates a SQL Managed Instance with a dedicated subnet, NSG, and route table.
#
# Requirements:
#   - 50 GB database capacity → 256 GB storage allocated (room for growth)
#   - 64 GB RAM minimum → 16 vCores on Business Critical Gen5 (~81.6 GB RAM)
#   - Business Critical tier → zone-redundant, built-in HA with local SSD
#
# SQL MI requires:
#   - A dedicated subnet delegated to Microsoft.Sql/managedInstances
#   - An NSG and route table associated with the subnet
#   - No other resources may share the SQL MI subnet
#
# Note: Initial provisioning can take 4-6 hours.
# =============================================================================

# --- SQL MI Subnet -----------------------------------------------------------
resource "azurerm_subnet" "sqlmi_subnet" {
  name                 = "dre-vnet1-sqlmi-subnet"
  resource_group_name  = var.vnet_resource_group
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.18.16.192/26"]

  delegation {
    name = "sqlmi-delegation"
    service_delegation {
      name = "Microsoft.Sql/managedInstances"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# --- SQL MI Network Security Group -------------------------------------------
resource "azurerm_network_security_group" "sqlmi_nsg" {
  name                = "cs-sqlmi-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { name = "cs-sqlmi-nsg" })
}

resource "azurerm_subnet_network_security_group_association" "sqlmi_nsg_assoc" {
  subnet_id                 = azurerm_subnet.sqlmi_subnet.id
  network_security_group_id = azurerm_network_security_group.sqlmi_nsg.id
}

# --- SQL MI Route Table ------------------------------------------------------
resource "azurerm_route_table" "sqlmi_rt" {
  name                = "cs-sqlmi-rt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { name = "cs-sqlmi-rt" })
}

resource "azurerm_subnet_route_table_association" "sqlmi_rt_assoc" {
  subnet_id      = azurerm_subnet.sqlmi_subnet.id
  route_table_id = azurerm_route_table.sqlmi_rt.id
}

# --- SQL Managed Instance ----------------------------------------------------
resource "azurerm_mssql_managed_instance" "sqlmi" {
  name                         = "cs-sqlmi-01"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  subnet_id                    = azurerm_subnet.sqlmi_subnet.id
  administrator_login          = var.admin_username
  administrator_login_password = var.sqlmi_admin_password
  sku_name                     = "BC_Gen5"             # Business Critical, Gen5 hardware
  vcores                       = 16                     # 16 vCores ≈ 81.6 GB RAM
  storage_size_in_gb           = 256                    # Supports 50 GB DB with growth room
  license_type                 = "BasePrice"            # Azure Hybrid Benefit (or "LicenseIncluded")
  minimum_tls_version          = "1.2"
  public_data_endpoint_enabled = false
  tags                         = merge(local.tags, { name = "cs-sqlmi-01" })

  depends_on = [
    azurerm_subnet_network_security_group_association.sqlmi_nsg_assoc,
    azurerm_subnet_route_table_association.sqlmi_rt_assoc,
  ]
}

# --- SQL MI Outputs ----------------------------------------------------------
output "sqlmi_fqdn" {
  description = "The fully qualified domain name of the SQL Managed Instance"
  value       = azurerm_mssql_managed_instance.sqlmi.fqdn
}

output "sqlmi_id" {
  description = "The Azure resource ID of the SQL Managed Instance"
  value       = azurerm_mssql_managed_instance.sqlmi.id
}
