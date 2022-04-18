module "rg" {
  source = "registry.terraform.io/libre-devops/rg/azurerm"

  rg_name    = "rg-${var.short}-${var.loc}-${terraform.workspace}-build"
  location   = local.location
  lock_level = "CanNotDelete"
  tags       = local.tags
}

module "network" {
  source = "registry.terraform.io/libre-devops/network/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location

  vnet_name     = "vnet-${var.short}-${var.loc}-${terraform.workspace}-01"
  vnet_location = module.network.vnet_location

  address_space   = ["10.0.0.0/16"]
  subnet_prefixes = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  subnet_names    = ["sn1-${module.network.vnet_name}", "sn2-${module.network.vnet_name}", "sn3-${module.network.vnet_name}"]

  subnet_service_endpoints = {
    subnet2 = ["Microsoft.Storage", "Microsoft.Sql"],
    subnet3 = ["Microsoft.AzureActiveDirectory"]
  }

  tags = local.tags
}

module "nsg" {
  source = "registry.terraform.io/libre-devops/nsg/azurerm"

  rg_name   = module.rg.rg_name
  location  = module.rg.rg_location
  nsg_name  = "nsg-build-${var.short}-${var.loc}-${terraform.workspace}-01"
  subnet_id = element(values(module.network.subnets_ids), 0)

  tags = module.rg.rg_tags
}

// Fix error which causes security errors to be flagged by TFSec, public egress is needed for Azure Bastion to function, its kind of the point :)
#tfsec:ignore:azure-network-no-public-egress
module "bastion" {
  source = "registry.terraform.io/libre-devops/bastion/azurerm"


  vnet_rg_name = module.network.vnet_rg_name
  vnet_name    = module.network.vnet_name

  bas_subnet_iprange = "10.0.4.0/28"

  bas_nsg_name     = "nsg-bas-${var.short}-${var.loc}-${terraform.workspace}-01"
  bas_nsg_location = module.rg.rg_location
  bas_nsg_rg_name  = module.rg.rg_name

  bas_pip_name              = "pip-bas-${var.short}-${var.loc}-${terraform.workspace}-01"
  bas_pip_location          = module.rg.rg_location
  bas_pip_rg_name           = module.rg.rg_name
  bas_pip_allocation_method = "Static"
  bas_pip_sku               = "Standard"

  bas_host_name          = "bas-${var.short}-${var.loc}-${terraform.workspace}-01"
  bas_host_location      = module.rg.rg_location
  bas_host_rg_name       = module.rg.rg_name
  bas_host_ipconfig_name = "bas-${var.short}-${var.loc}-${terraform.workspace}-01-ipconfig"

  tags = module.rg.rg_tags
}

locals {
  vm_amount = 1
}

module "win_vm" {
  source = "registry.terraform.io/libre-devops/windows-vm/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location

  vm_amount          = local.vm_amount
  vm_hostname        = "vm${var.short}${var.loc}${terraform.workspace}"
  vm_size            = "Standard_B2ms"
  vm_os_simple       = "WindowsServer2019"
  vm_os_disk_size_gb = "127"

  asg_name = "asg-${regexall("[a-z]+", module.win_vm.vm_name)}-${var.short}-${var.loc}-${terraform.workspace}"

  admin_username = "LibreDevOpsAdmin"
  admin_password = data.azurerm_key_vault_secret.mgmt_local_admin_pwd.value

  subnet_id            = element(values(module.network.subnets_ids), 0)
  availability_zone    = "alternate"
  storage_account_type = "Standard_LRS"
  identity_type        = "SystemAssigned"

  tags = module.rg.rg_tags
}


// Allow Inbound Access from Bastion
resource "azurerm_network_security_rule" "AllowSSHRDPInboundFromBasSubnet" {
  name                                       = "AllowBasSSHRDPInbound"
  priority                                   = 400
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_ranges                    = ["22", "3389"]
  source_address_prefixes                    = module.bastion.bas_subnet_ip_range
  destination_address_prefixes               = module.network.vnet_address_space
  resource_group_name                        = module.rg.rg_name
  network_security_group_name                = module.nsg.nsg_name
}

// If running locally, running this block will fetch your outbound public IP of your home/office/ISP/VPN and add it.  It will add the hosted agent etc if running from Microsoft/GitLab
data "http" "user_ip" {
  url = "https://ipv4.icanhazip.com"
}

// Allow Inbound Access from Bastion
resource "azurerm_network_security_rule" "AllowSSHRDPInboundFromHomeSubnet" {
  name                                       = "AllowBasSSHRDPFromHomeInbound"
  priority                                   = 405
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_ranges                    = ["22", "3389"]
  source_address_prefixes                    = [chomp(data.http.user_ip.body)]
  destination_address_prefixes               = module.network.vnet_address_space
  resource_group_name                        = module.rg.rg_name
  network_security_group_name                = module.nsg.nsg_name
}