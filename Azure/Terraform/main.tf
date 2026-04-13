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
    name                          = "internal"
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
