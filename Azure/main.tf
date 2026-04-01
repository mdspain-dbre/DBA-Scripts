terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "148f67ee-68bc-429e-916b-4ca8568f3c6d"
}

# Variables
variable "vm_name" {
  default = "cs-win-vm-01"
}

variable "location" {
  default = "westus2"
}

variable "resource_group_name" {
  default = "content-services-documentdb"
}

variable "admin_username" {
  default = "dreadmin"
}

variable "admin_password" {
  sensitive = true
}

variable "vm_size" {
  default = "Standard_D2s_v3"
}

variable "vnet_resource_group" {
  default = "DRE-sandbox-network-rg"
}

variable "vnet_name" {
  default = "dre-vnet1"
}

variable "subnet_name" {
  default = "dre-vnet1-subnet1"
}

# Common tags matching content-services convention
locals {
  tags = {
    apmid                = "APM0000000"
    applicationname      = "content-services"
    "cost-center"        = "2650"
    "created-by"         = "michael dspain"
    environment          = "dev"
    function             = "content-services"
    name                 = var.vm_name
    notificationdistlist = "cpie-dre@vizio.com"
    owner                = "cpie-dre"
    repo                 = "CognitiveNetworks/evergreen-inscape-iac"
    service              = "content-services"
    ssp                  = "00000000"
    trproductid          = "6055"
  }
}

# Reference existing subnet in a different resource group
data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group
}

# NSG
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.vm_name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

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
}

# NIC (no public IP - disallowed by policy)
resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Associate NSG with NIC
resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Windows VM with Trusted Launch
resource "azurerm_windows_virtual_machine" "vm" {
  name                = var.vm_name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.nic.id]

  security_type = "TrustedLaunch"
  vtpm_enabled  = true
  secure_boot_enabled = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    tags                 = local.tags
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }
}

# 1TB data disk
resource "azurerm_managed_disk" "data_disk" {
  name                 = "${var.vm_name}-datadisk-01"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 1024
  tags                 = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data_disk_attach" {
  managed_disk_id    = azurerm_managed_disk.data_disk.id
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadWrite"
}

# Outputs
output "private_ip_address" {
  value = azurerm_network_interface.nic.private_ip_address
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.vm.id
}
