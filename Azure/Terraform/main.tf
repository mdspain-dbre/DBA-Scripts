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
# SQL SERVER VM — VARIABLES
# =============================================================================
# Separate variables for the SQL Server VM so it can be sized and named
# independently from the existing Windows utility VM.
# =============================================================================

variable "sql_vm_name" {
  description = "Name for the SQL Server VM and related resources."
  default     = "cs-sql-vm-01"
}

variable "sql_vm_size" {
  description = "Azure VM size. Must support >= 13 data disks. Standard_E8ds_v5 = 8 vCPUs, 64 GB RAM, 16 data disks max."
  default     = "Standard_E8ds_v5"
}

variable "sql_vm_sku" {
  description = "SQL Server marketplace image SKU (enterprise-gen2, standard-gen2, sqldev-gen2, web-gen2)."
  default     = "sqldev-gen2"
}

# SQL Server SA password for SQL Authentication. Marked "sensitive" so
# Terraform won't display it in plan output or logs. Must meet SQL Server
# complexity requirements: 8+ chars, upper, lower, number, special character.
variable "sql_sa_password" {
  description = "SA password for SQL Server authentication."
  sensitive   = true
}

# =============================================================================
# SQL SERVER VM — NETWORK SECURITY GROUP
# =============================================================================
# Dedicated NSG for the SQL VM. Allows inbound RDP (3389) and SQL Server
# (1433). In production, restrict source_address_prefix to your VPN/office CIDR.
# =============================================================================
resource "azurerm_network_security_group" "sql_nsg" {
  name                = "${var.sql_vm_name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { name = "${var.sql_vm_name}-nsg" })

  security_rule {
    name                       = "AllowRDP"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSQL"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# =============================================================================
# SQL SERVER VM — NETWORK INTERFACE
# =============================================================================
resource "azurerm_network_interface" "sql_nic" {
  name                = "${var.sql_vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { name = "${var.sql_vm_name}-nic" })

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "sql_nic_nsg" {
  network_interface_id      = azurerm_network_interface.sql_nic.id
  network_security_group_id = azurerm_network_security_group.sql_nsg.id
}

# =============================================================================
# SQL SERVER VM — VIRTUAL MACHINE
# =============================================================================
# Uses a SQL Server 2022 Enterprise marketplace image on Windows Server 2022.
# Gen2 is required for TrustedLaunch (default in azurerm v4.x).
#
# The VM size (Standard_E8ds_v5) provides:
#   - 8 vCPUs, 64 GB RAM (memory-optimized for SQL Server)
#   - Up to 16 data disk slots (we use 13)
#   - Local temp SSD for pagefile
# =============================================================================
resource "azurerm_windows_virtual_machine" "sql_vm" {
  name                = var.sql_vm_name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.sql_vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = merge(local.tags, { name = var.sql_vm_name })

  network_interface_ids = [azurerm_network_interface.sql_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = var.sql_vm_sku
    version   = "latest"
  }
}

# =============================================================================
# SQL SERVER VM — MANAGED DISKS
# =============================================================================
# Disk-to-Drive Layout:
#
#   LUN   Drive   Purpose          Count   Size    RAID Level
#   ───   ─────   ───────          ─────   ────    ──────────
#    0    D:\     System DBs         1     256 GB   None (single disk)
#   1-4   F:\     User Data          4     512 GB   RAID 10 (Mirror, 2 cols)
#   5-8   L:\     User Logs          4     256 GB   RAID 10 (Mirror, 2 cols)
#   9-12  T:\     TempDB             4     128 GB   RAID 0  (Simple, 4 cols)
#
# RAID 10 = Windows Storage Spaces Mirror with 2 columns across 4 disks
#           (2 striped mirror pairs). 50% usable capacity, fault tolerant.
# RAID 0  = Windows Storage Spaces Simple with 4 columns across 4 disks
#           (full stripe). 100% usable capacity, maximum IOPS.
#
# All volumes use 64 KB allocation unit size (SQL Server best practice).
# =============================================================================

# --- D:\ System DBs — 1 × 256 GB Premium SSD (LUN 0) ---
resource "azurerm_managed_disk" "sql_system_disk" {
  name                 = "${var.sql_vm_name}-system-lun0"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 256
  tags                 = merge(local.tags, { name = "${var.sql_vm_name}-system-lun0" })
}

# --- F:\ User Data — 4 × 512 GB Premium SSD (LUNs 1-4) ---
resource "azurerm_managed_disk" "sql_data_disk" {
  count                = 4
  name                 = "${var.sql_vm_name}-data-lun${count.index + 1}"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 512
  tags                 = merge(local.tags, { name = "${var.sql_vm_name}-data-lun${count.index + 1}" })
}

# --- L:\ User Logs — 4 × 256 GB Premium SSD (LUNs 5-8) ---
resource "azurerm_managed_disk" "sql_log_disk" {
  count                = 4
  name                 = "${var.sql_vm_name}-log-lun${count.index + 5}"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 256
  tags                 = merge(local.tags, { name = "${var.sql_vm_name}-log-lun${count.index + 5}" })
}

# --- T:\ TempDB — 4 × 128 GB Premium SSD (LUNs 9-12) ---
resource "azurerm_managed_disk" "sql_tempdb_disk" {
  count                = 4
  name                 = "${var.sql_vm_name}-tempdb-lun${count.index + 9}"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 128
  tags                 = merge(local.tags, { name = "${var.sql_vm_name}-tempdb-lun${count.index + 9}" })
}

# =============================================================================
# SQL SERVER VM — DISK ATTACHMENTS
# =============================================================================
# Caching best practices for SQL Server:
#   - Data files (F:\): ReadOnly  — improves read-heavy query workloads
#   - System DBs (D:\): ReadOnly  — mostly read after initial setup
#   - Log files  (L:\): None      — sequential writes, caching adds overhead
#   - TempDB     (T:\): None      — write-heavy, direct disk = fastest
#
# Azure only allows one VM update at a time. Disk attachments are serialized
# via depends_on to prevent 409 ConflictingConcurrentWrite errors.
# =============================================================================

resource "azurerm_virtual_machine_data_disk_attachment" "sql_system_attach" {
  managed_disk_id    = azurerm_managed_disk.sql_system_disk.id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id
  lun                = 0
  caching            = "ReadOnly"
}

resource "azurerm_virtual_machine_data_disk_attachment" "sql_data_attach" {
  count              = 4
  managed_disk_id    = azurerm_managed_disk.sql_data_disk[count.index].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id
  lun                = count.index + 1
  caching            = "ReadOnly"

  depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_system_attach]
}

resource "azurerm_virtual_machine_data_disk_attachment" "sql_log_attach" {
  count              = 4
  managed_disk_id    = azurerm_managed_disk.sql_log_disk[count.index].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id
  lun                = count.index + 5
  caching            = "None"

  depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_data_attach]
}

resource "azurerm_virtual_machine_data_disk_attachment" "sql_tempdb_attach" {
  count              = 4
  managed_disk_id    = azurerm_managed_disk.sql_tempdb_disk[count.index].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id
  lun                = count.index + 9
  caching            = "None"

  depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_log_attach]
}

# =============================================================================
# SQL SERVER VM — STORAGE SPACES CONFIGURATION
# =============================================================================
# After all 13 data disks are attached, this run command executes a PowerShell
# script inside the VM to:
#   1. Relocate the Azure temp/pagefile disk from D: to Z:
#   2. Create Storage Spaces pools grouped by LUN range
#   3. Build virtual disks with the correct resiliency (Mirror or Simple)
#   4. Partition and format each drive with 64 KB NTFS allocation units
#   5. Create SQL Server subdirectories on each drive
#   6. Set SQL Server default data/log paths and move TempDB files
#
# Storage Spaces Mirror with NumberOfColumns=2 across 4 disks creates two
# striped mirror pairs — the equivalent of RAID 10.
# Storage Spaces Simple with NumberOfColumns=4 creates a four-column stripe
# across all disks — the equivalent of RAID 0.
# =============================================================================
resource "azurerm_virtual_machine_run_command" "sql_storage_config" {
  name               = "configure-sql-storage"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id
  tags               = merge(local.tags, { name = "configure-sql-storage" })

  source {
    script = <<-PWSH
      $ErrorActionPreference = 'Stop'

      # ── Install DBATools module ────────────────────────────────────────
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
      Install-Module dbatools -Force -SkipPublisherCheck -Scope AllUsers
      Import-Module dbatools -Force
      Write-Output 'DBATools module installed and imported.'

      # ── SQL credential for SA auth ─────────────────────────────────────
      $saSecure = ConvertTo-SecureString '${var.sql_sa_password}' -AsPlainText -Force
      $sqlCred = New-Object System.Management.Automation.PSCredential('sa', $saSecure)
      $inst = 'localhost'

      # ── Relocate Azure temp/pagefile disk from D: to Z: ──────────────────
      try {
          $tempPart = Get-Partition -DriveLetter D -ErrorAction SilentlyContinue
          if ($tempPart) {
              Set-Partition -DriveLetter D -NewDriveLetter Z
              Write-Output 'Relocated Azure temp disk from D: to Z:'
              Start-Sleep -Seconds 5
          }
      } catch { Write-Warning "Temp disk relocation via Get-Partition: $_" }

      # Fallback: try WMI if Get-Partition didn't find it
      try {
          $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='D:'" -ErrorAction SilentlyContinue
          if ($vol) {
              Set-CimInstance -InputObject $vol -Property @{DriveLetter='Z:'}
              Write-Output 'Relocated Azure temp disk from D: to Z: (WMI fallback)'
              Start-Sleep -Seconds 5
          }
      } catch { Write-Warning "Temp disk relocation via WMI: $_" }

      Start-Sleep -Seconds 5

      # ── Helper: find physical disks by LUN number ───────────────────────
      function Get-DisksByLUN {
          param([int[]]$LUNs)
          Get-PhysicalDisk -CanPool $true | Where-Object {
              $_.PhysicalLocation -match 'LUN\s+(\d+)' -and [int]$Matches[1] -in $LUNs
          }
      }

      # ── Helper: create a Storage Spaces pool, virtual disk, and volume ──
      # Idempotent — skips any step that already completed.
      # Avoids cmdlet calls inside if() conditions (causes parse errors in
      # RunCommand context).
      function New-SQLDrive {
          param(
              [string]$Pool,
              [string]$VDisk,
              [string]$Label,
              [char]$Letter,
              [string]$Resiliency,
              [int]$Cols,
              [object[]]$Disks
          )

          # Skip if drive letter already exists as a writable volume
          # (ignore CD-ROM / DriveType 5 — it gets relocated above)
          $chkVol = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
          if ($chkVol -and $chkVol.DriveType -ne 'CD-ROM') {
              Write-Output "$Letter`: already exists - skipping"
              return
          }

          # Create pool if it doesn't exist
          $chkPool = Get-StoragePool -FriendlyName $Pool -ErrorAction SilentlyContinue
          if (-not $chkPool) {
              New-StoragePool -FriendlyName $Pool -StorageSubSystemFriendlyName "Windows Storage*" -PhysicalDisks $Disks
          }

          # Create virtual disk if it doesn't exist
          $chkVD = Get-VirtualDisk -FriendlyName $VDisk -ErrorAction SilentlyContinue
          if (-not $chkVD) {
              New-VirtualDisk -StoragePoolFriendlyName $Pool -FriendlyName $VDisk -ResiliencySettingName $Resiliency -NumberOfColumns $Cols -UseMaximumSize
          }

          $d = Get-VirtualDisk -FriendlyName $VDisk | Get-Disk

          # Initialize if raw
          if ($d.PartitionStyle -eq 'RAW') {
              Initialize-Disk -Number $d.Number -PartitionStyle GPT
          }

          # Try to create partition; if it already exists, just assign the letter
          try {
              New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter $Letter -ErrorAction Stop
              Format-Volume -DriveLetter $Letter -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel $Label -Confirm:$false
          }
          catch {
              Write-Output "New-Partition failed (partition may already exist): $_"
              # Check if the volume somehow already has the right letter
              $existVol = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
              if ($existVol) {
                  Write-Output "$Letter`: volume already exists after failed New-Partition - OK"
                  return
              }
              # Find the largest partition on this disk and assign the letter
              $dataPart = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Size -Descending | Select-Object -First 1
              if ($dataPart -and -not $dataPart.DriveLetter) {
                  Set-Partition -InputObject $dataPart -NewDriveLetter $Letter
                  Write-Output "Assigned $Letter`: to existing partition"
              }
          }
      }

      # ── D: System DBs — LUN 0, Simple (single disk) ────────────────────
      New-SQLDrive -Pool "SQLSystemPool" -VDisk "SQLSystemVDisk" -Label "SystemDBs" -Letter D -Resiliency Simple -Cols 1 -Disks (Get-DisksByLUN -LUNs @(0))

      # ── F: User Data — LUNs 1-4, Mirror (RAID 10) ─────────────────────
      New-SQLDrive -Pool "SQLDataPool" -VDisk "SQLDataVDisk" -Label "SQLData" -Letter F -Resiliency Mirror -Cols 2 -Disks (Get-DisksByLUN -LUNs @(1,2,3,4))

      # ── L: User Logs — LUNs 5-8, Mirror (RAID 10) ─────────────────────
      New-SQLDrive -Pool "SQLLogPool" -VDisk "SQLLogVDisk" -Label "SQLLogs" -Letter L -Resiliency Mirror -Cols 2 -Disks (Get-DisksByLUN -LUNs @(5,6,7,8))

      # ── T: TempDB — LUNs 9-12, Simple (RAID 0) ────────────────────────
      New-SQLDrive -Pool "SQLTempPool" -VDisk "SQLTempVDisk" -Label "TempDB" -Letter T -Resiliency Simple -Cols 4 -Disks (Get-DisksByLUN -LUNs @(9,10,11,12))

      # ── Create SQL Server directories ──────────────────────────────────
      foreach ($dir in @('D:\SQLSystemDBs','F:\SQLData','L:\SQLLogs','T:\TempDB')) {
          try {
              New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
              Write-Output "Created directory: $dir"
          } catch {
              Write-Warning "Could not create $dir : $_"
          }
      }

      # ── Ensure SQL Server is running before DBATools calls ─────────────
      $sqlSvc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
      $sqlRunning = $sqlSvc.Status -eq 'Running'
      if (-not $sqlRunning) {
          Write-Output 'SQL Server is not running - determining where DB files are...'
          $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\Parameters'
          $defaultData = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'
          $newData = 'D:\SQLSystemDBs'

          # Check if files already moved to D:\SQLSystemDBs
          $masterOnD = Test-Path "$newData\master.mdf"
          $masterOnC = Test-Path "$defaultData\master.mdf"

          if ($masterOnD) {
              # Files are on D: - point startup params there and grant permissions
              Write-Output 'DB files found on D:\SQLSystemDBs - starting from there...'
              Set-ItemProperty -Path $regPath -Name 'SQLArg0' -Value "-d$newData\master.mdf"
              Set-ItemProperty -Path $regPath -Name 'SQLArg2' -Value "-l$newData\mastlog.ldf"
              Set-ItemProperty -Path $regPath -Name 'SQLArg1' -Value "-e$newData\ERRORLOG"
              # Grant SQL service permissions
              $acl = Get-Acl -Path $newData
              $rule = New-Object System.Security.AccessControl.FileSystemAccessRule('NT Service\MSSQLSERVER', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
              $acl.AddAccessRule($rule)
              Set-Acl -Path $newData -AclObject $acl
              Write-Output 'Granted SQL service permissions on D:\SQLSystemDBs'
          }
          elseif ($masterOnC) {
              # Files still on C: - use defaults
              Write-Output 'DB files found at default location - starting from there...'
              Set-ItemProperty -Path $regPath -Name 'SQLArg0' -Value "-d$defaultData\master.mdf"
              Set-ItemProperty -Path $regPath -Name 'SQLArg2' -Value "-l$defaultData\mastlog.ldf"
              Set-ItemProperty -Path $regPath -Name 'SQLArg1' -Value "-e$defaultData\ERRORLOG"
          }
          else {
              Write-Warning 'master.mdf not found on C: or D: - SQL Server may not start!'
          }

          Start-Service -Name 'MSSQLSERVER'
          Start-Sleep -Seconds 20
          $svcCheck = Get-Service -Name 'MSSQLSERVER'
          Write-Output "SQL Server status: $($svcCheck.Status)"
      }

      # ── PHASE 1: Configure everything while SQL is running ─────────────

      # Default data/log paths
      try {
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', REG_SZ, N'F:\SQLData'"
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', REG_SZ, N'L:\SQLLogs'"
          Write-Output 'Default data/log paths configured.'
      } catch { Write-Warning "Default path configuration: $_" }

      # TempDB: 8 data files + 1 log on T:\TempDB
      try {
          Set-DbaTempDbConfig -SqlInstance $inst -SqlCredential $sqlCred -DataFileCount 8 -DataPath 'T:\TempDB' -LogPath 'T:\TempDB' -DataFileSize 512 -DataFileGrowth 256 -LogFileSize 256 -LogFileGrowth 128 -EnableException
          Write-Output 'TempDB: 8 data files + 1 log configured on T:\TempDB.'
      } catch { Write-Warning "TempDB config: $_" }

      # model and msdb ALTER DATABASE to D:\SQLSystemDBs
      try {
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "ALTER DATABASE model MODIFY FILE (NAME = modeldev, FILENAME = 'D:\SQLSystemDBs\model.mdf')"
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "ALTER DATABASE model MODIFY FILE (NAME = modellog, FILENAME = 'D:\SQLSystemDBs\modellog.ldf')"
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "ALTER DATABASE msdb MODIFY FILE (NAME = MSDBData, FILENAME = 'D:\SQLSystemDBs\MSDBData.mdf')"
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "ALTER DATABASE msdb MODIFY FILE (NAME = MSDBLog, FILENAME = 'D:\SQLSystemDBs\MSDBLog.ldf')"
          Write-Output 'model and msdb configured for D:\SQLSystemDBs.'
      } catch { Write-Warning "model/msdb move: $_" }

      # master startup parameters
      try {
          Set-DbaStartupParameter -SqlInstance $inst -MasterData 'D:\SQLSystemDBs\master.mdf' -MasterLog 'D:\SQLSystemDBs\mastlog.ldf' -ErrorLog 'D:\SQLSystemDBs\ERRORLOG' -Confirm:$false
          Write-Output 'Master startup parameters updated.'
      } catch { Write-Warning "Master startup parameter update: $_" }

      # sp_configure settings
      try {
          Set-DbaSpConfigure -SqlInstance $inst -SqlCredential $sqlCred -Name ShowAdvancedOptions -Value 1 -EnableException
          Set-DbaMaxMemory -SqlInstance $inst -SqlCredential $sqlCred -Max 54272 -EnableException
          Write-Output 'Max Server Memory set to 54272 MB (85% of 64 GB).'
      } catch { Write-Warning "Max Server Memory: $_" }

      try {
          Set-DbaSpConfigure -SqlInstance $inst -SqlCredential $sqlCred -Name RemoteDacConnectionsEnabled -Value 1 -EnableException
          Write-Output 'Remote Dedicated Admin Connection (DAC) enabled.'
      } catch { Write-Warning "DAC enable: $_" }

      try {
          Set-DbaSpConfigure -SqlInstance $inst -SqlCredential $sqlCred -Name MaxDegreeOfParallelism -Value 8 -EnableException
          Set-DbaSpConfigure -SqlInstance $inst -SqlCredential $sqlCred -Name CostThresholdForParallelism -Value 75 -EnableException
          Write-Output 'MAXDOP set to 8, Cost Threshold for Parallelism set to 75.'
      } catch { Write-Warning "MAXDOP/CTP: $_" }

      try {
          Set-DbaSpConfigure -SqlInstance $inst -SqlCredential $sqlCred -Name DefaultBackupCompression -Value 1 -EnableException
          Write-Output 'Backup compression default enabled.'
      } catch { Write-Warning "Backup compression: $_" }

      try {
          Invoke-DbaQuery -SqlInstance $inst -SqlCredential $sqlCred -Query "ALTER DATABASE model SET READ_COMMITTED_SNAPSHOT ON"
          Write-Output 'Read Committed Snapshot Isolation enabled on model database.'
      } catch { Write-Warning "RCSI model: $_" }

      # Mixed Mode authentication
      try {
          Set-DbaInstanceAuthenticationMode -SqlInstance $inst -AuthenticationMode Mixed -Confirm:$false
          Write-Output 'SQL Server authentication set to Mixed Mode.'
      } catch { Write-Warning "Mixed Mode: $_" }

      # ── PHASE 2: Stop SQL Server ──────────────────────────────────────
      Write-Output 'Stopping SQL Server Agent...'
      Stop-Service -Name 'SQLSERVERAGENT' -Force -ErrorAction SilentlyContinue
      Write-Output 'Stopping SQL Server...'
      Stop-Service -Name 'MSSQLSERVER' -Force
      Start-Sleep -Seconds 10
      Write-Output 'SQL Server stopped.'

      # ── PHASE 3: Move system DB files to D:\SQLSystemDBs ──────────────
      # Grant SQL Server service accounts full control on all SQL directories
      try {
          $sqlDirs = @('D:\SQLSystemDBs','F:\SQLData','L:\SQLLogs','T:\TempDB')
          $accounts = @('NT Service\MSSQLSERVER','NT Service\SQLSERVERAGENT')
          foreach ($dir in $sqlDirs) {
              $acl = Get-Acl -Path $dir
              foreach ($acct in $accounts) {
                  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($acct, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                  $acl.AddAccessRule($rule)
              }
              Set-Acl -Path $dir -AclObject $acl
              Write-Output "Granted SQL service permissions on $dir"
          }
      } catch { Write-Warning "ACL setup: $_" }

      try {
          $defaultData = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'
          $filesToCopy = @('master.mdf','mastlog.ldf','model.mdf','modellog.ldf','MSDBData.mdf','MSDBLog.ldf')
          foreach ($f in $filesToCopy) {
              $src = Join-Path $defaultData $f
              $dst = Join-Path 'D:\SQLSystemDBs' $f
              $srcExists = Test-Path $src
              $dstExists = Test-Path $dst
              if ($srcExists -and -not $dstExists) {
                  Copy-Item -Path $src -Destination $dst -Force
                  Write-Output "Copied $f to D:\SQLSystemDBs"
              }
          }
      } catch { Write-Warning "File copy: $_" }

      # ── PHASE 4: Start SQL Server ─────────────────────────────────────
      Write-Output 'Starting SQL Server...'
      Start-Service -Name 'MSSQLSERVER'
      Start-Sleep -Seconds 30
      $svc = Get-Service -Name 'MSSQLSERVER'
      Write-Output "SQL Server: $($svc.Status)"

      # Wait for SQL Agent to come online (dependent service)
      $retries = 0
      $agtsvc = Get-Service -Name 'SQLSERVERAGENT'
      while ($agtsvc.Status -ne 'Running' -and $retries -lt 12) {
          Start-Sleep -Seconds 5
          $agtsvc = Get-Service -Name 'SQLSERVERAGENT'
          $retries++
      }
      Write-Output "SQL Agent: $($agtsvc.Status) (checked $retries times)"

      # ── PHASE 5: Create Agent Job ─────────────────────────────────────
      try {
          $existingJob = Get-DbaAgentJob -SqlInstance $inst -SqlCredential $sqlCred -Job 'Cycle Error Log' -ErrorAction SilentlyContinue
          if ($existingJob) {
              Remove-DbaAgentJob -SqlInstance $inst -SqlCredential $sqlCred -Job 'Cycle Error Log' -Confirm:$false
          }
          New-DbaAgentJob -SqlInstance $inst -SqlCredential $sqlCred -Job 'Cycle Error Log' -Description 'Cycles the SQL Server error log nightly at midnight.' -OwnerLogin 'sa' -Enabled
          New-DbaAgentJobStep -SqlInstance $inst -SqlCredential $sqlCred -Job 'Cycle Error Log' -StepName 'Cycle Error Log' -Subsystem TransactSql -Command 'EXEC sp_cycle_errorlog' -Database 'master'
          New-DbaAgentSchedule -SqlInstance $inst -SqlCredential $sqlCred -Job 'Cycle Error Log' -Schedule 'Nightly Midnight' -FrequencyType Daily -FrequencyInterval EveryDay -StartTime '000000' -Force
          Write-Output 'Agent Job: Cycle Error Log created (nightly at midnight).'
      } catch { Write-Warning "Cycle Error Log job: $_" }

      Write-Output 'All configuration complete. SQL Server has been restarted.'
    PWSH
  }

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.sql_system_attach,
    azurerm_virtual_machine_data_disk_attachment.sql_data_attach,
    azurerm_virtual_machine_data_disk_attachment.sql_log_attach,
    azurerm_virtual_machine_data_disk_attachment.sql_tempdb_attach,
  ]
}

# =============================================================================
# SQL SERVER VM — SQL IAAS AGENT REGISTRATION
# =============================================================================
# Registers the VM with the SQL IaaS Agent extension for licensing management,
# automated patching, and Azure portal integration. Storage is configured
# separately via the run command above (Storage Spaces RAID 10/0 is not
# supported by the built-in storage_configuration block).
# =============================================================================
resource "azurerm_mssql_virtual_machine" "sql_vm_config" {
  virtual_machine_id               = azurerm_windows_virtual_machine.sql_vm.id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = var.sql_sa_password
  sql_connectivity_update_username = "sa"
  tags                             = merge(local.tags, { name = var.sql_vm_name })

  depends_on = [azurerm_virtual_machine_run_command.sql_storage_config]
}

# =============================================================================
# SQL SERVER VM — OUTPUTS
# =============================================================================
output "sql_vm_private_ip" {
  description = "Private IP address of the SQL Server VM"
  value       = azurerm_network_interface.sql_nic.private_ip_address
}

output "sql_vm_id" {
  description = "Azure resource ID of the SQL Server VM"
  value       = azurerm_windows_virtual_machine.sql_vm.id
}

