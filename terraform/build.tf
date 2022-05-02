module "rg" {
  source = "registry.terraform.io/libre-devops/rg/azurerm"

  rg_name  = "rg-${var.short}-${var.loc}-${terraform.workspace}-build" // rg-ldo-euw-dev-build
  location = local.location                                            // compares var.loc with the var.regions var to match a long-hand name, in this case, "euw", so "westeurope"
  tags     = local.tags

  #  lock_level = "CanNotDelete" // Do not set this value to skip lock
}

module "network" {
  source = "registry.terraform.io/libre-devops/network/azurerm"

  rg_name  = module.rg.rg_name // rg-ldo-euw-dev-build
  location = module.rg.rg_location
  tags     = local.tags

  vnet_name     = "vnet-${var.short}-${var.loc}-${terraform.workspace}-01" // vnet-ldo-euw-dev-01
  vnet_location = module.network.vnet_location

  address_space   = ["10.0.0.0/16"]
  subnet_prefixes = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  subnet_names    = ["sn1-${module.network.vnet_name}", "sn2-${module.network.vnet_name}", "sn3-${module.network.vnet_name}"] //sn1-vnet-ldo-euw-dev-01
  subnet_service_endpoints = {
    "sn1-${module.network.vnet_name}" = ["Microsoft.Storage"]                   // Adds extra subnet endpoints to sn1-vnet-ldo-euw-dev-01
    "sn2-${module.network.vnet_name}" = ["Microsoft.Storage", "Microsoft.Sql"], // Adds extra subnet endpoints to sn2-vnet-ldo-euw-dev-01
    "sn3-${module.network.vnet_name}" = ["Microsoft.AzureActiveDirectory"]      // Adds extra subnet endpoints to sn3-vnet-ldo-euw-dev-01
  }
}

module "nsg" {
  source = "registry.terraform.io/libre-devops/nsg/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location
  tags     = module.rg.rg_tags

  nsg_name  = "nsg-${element(keys(module.network.subnets_ids), 0)}" // nsg-sn1-vnet-ldo-euw-dev-01
  subnet_id = element(values(module.network.subnets_ids), 0)        // Adds NSG to all subnets
}

data "http" "user_ip" {
  url = "https://ipv4.icanhazip.com" // If running locally, running this block will fetch your outbound public IP of your home/office/ISP/VPN and add it.  It will add the hosted agent etc if running from Microsoft/GitLab
}

// This module does not consider for CMKs and allows the users to manually set bypasses
#checkov:skip=CKV2_AZURE_1:CMKs are not considered in this module
#checkov:skip=CKV2_AZURE_18:CMKs are not considered in this module
#checkov:skip=CKV_AZURE_33:Storage logging is not configured by default in this module
#tfsec:ignore:azure-storage-queue-services-logging-enabled tfsec:ignore:azure-storage-allow-microsoft-service-bypass
module "sa" {
  source = "registry.terraform.io/libre-devops/storage-account/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location
  tags     = module.rg.rg_tags

  storage_account_name = "st${var.short}${var.loc}${terraform.workspace}01"
  access_tier          = "Hot"
  identity_type        = "SystemAssigned"

  storage_account_properties = {

    // Set this block to enable network rules
    network_rules = {
      default_action = "Deny"
      bypass         = ["AzureServices", "Metrics", "Logging"]
      ip_rules       = [chomp(data.http.user_ip.body)]
      subnet_ids     = [element(values(module.network.subnets_ids), 0)]
    }

    blob_properties = {
      versioning_enabled       = false
      change_feed_enabled      = false
      default_service_version  = "2020-06-12"
      last_access_time_enabled = false

      deletion_retention_policies = {
        days = 10
      }

      container_delete_retention_policy = {
        days = 10
      }
    }

    routing = {
      publish_internet_endpoints  = false
      publish_microsoft_endpoints = true
      choice                      = "MicrosoftRouting"
    }
  }
}

// Default behaviour uses "registry.terraform.io/libre-devops/windows-os-plan-calculator/azurerm"
module "win_vm_simple" {
  source = "registry.terraform.io/libre-devops/windows-vm/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location
  tags     = module.rg.rg_tags

  vm_amount          = 1
  vm_hostname        = "win${var.short}${var.loc}${terraform.workspace}" // winldoeuwdev01 & winldoeuwdev02 & winldoeuwdev03
  vm_size            = "Standard_B2ms"
  use_simple_image   = true
  vm_os_simple       = "WindowsServer2019"
  vm_os_disk_size_gb = "127"

  asg_name = "asg-${element(regexall("[a-z]+", element(module.win_vm_simple.vm_name, 0)), 0)}-${var.short}-${var.loc}-${terraform.workspace}-01" //asg-vmldoeuwdev-ldo-euw-dev-01 - Regex strips all numbers from string

  admin_username = "LibreDevOpsAdmin"
  admin_password = data.azurerm_key_vault_secret.mgmt_local_admin_pwd.value // Created with the Libre DevOps Terraform Pre-Requisite script

  subnet_id            = element(values(module.network.subnets_ids), 0) // Places in sn1-vnet-ldo-euw-dev-01
  availability_zone    = "alternate"                                    // If more than 1 VM exists, places them in alterate zones, 1, 2, 3 then resetting.  If you want HA, use an availability set.
  storage_account_type = "Standard_LRS"
  identity_type        = "SystemAssigned"
}

// Want to use this module without the SKU calculator? Try something like this:
#module "win_vm_with_custom_image" {
#  source = "registry.terraform.io/libre-devops/windows-vm/azurerm"
#
#  rg_name  = module.rg.rg_name
#  location = module.rg.rg_location
#  tags     = module.rg.rg_tags
#
#  vm_amount   = 1
#  vm_hostname = "vm${var.short}${var.loc}${terraform.workspace}" // vmldoeuwdev01
#  vm_size     = "Standard_B2ms"
#
#  use_simple_image = false
#  source_image_reference = {
#    publisher = "MicrosoftWindowsServer"
#    offer     = "WindowsServer"
#    sku       = "2019-Datacenter"
#    version   = "latest"
#  }
#
#  vm_os_disk_size_gb = "127"
#
#  asg_name = "asg-${element(regexall("[a-z]+", element(module.win_vm_with_custom_image.vm_name, 0)), 0)}-${var.short}-${var.loc}-${terraform.workspace}-01" //asg-vmldoeuwdev-ldo-euw-dev-01 - Regex strips all numbers from string
#
#  admin_username = "LibreDevOpsAdmin"
#  admin_password = data.azurerm_key_vault_secret.mgmt_local_admin_pwd.value // Created with the Libre DevOps Terraform Pre-Requisite script
#
#  subnet_id            = element(values(module.network.subnets_ids), 0) // Places in sn1-vnet-ldo-euw-dev-01
#  availability_zone    = "alternate"                                    // If more than 1 VM exists, places them in alterate zones, 1, 2, 3 then resetting.  If you want HA, use an availability set.
#  storage_account_type = "Standard_LRS"
#  identity_type        = "UserAssigned"
#  identity_ids         = [data.azurerm_user_assigned_identity.mgmt_user_assigned_id.id]
#}

// Sometimes you may want an image like the CIS images, these are part of a plan rather than the platform images.  You can use the ""registry.terraform.io/libre-devops/windows-os-plan-with-plan-calculator/azurerm""
module "win_vm_with_plan" {
  source = "registry.terraform.io/libre-devops/windows-vm/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location
  tags     = module.rg.rg_tags

  vm_amount   = 1
  vm_hostname = "vm${var.short}${var.loc}${terraform.workspace}" // vmldoeuwdev01
  vm_size     = "Standard_B2ms"

  use_simple_image_with_plan = true
  vm_os_simple               = "CISWindowsServer2019L1"

  vm_os_disk_size_gb = "127"

  asg_name = "asg-${element(regexall("[a-z]+", element(module.win_vm_with_plan.vm_name, 0)), 0)}-${var.short}-${var.loc}-${terraform.workspace}-01" //asg-vmldoeuwdev-ldo-euw-dev-01 - Regex strips all numbers from string

  admin_username = "LibreDevOpsAdmin"
  admin_password = data.azurerm_key_vault_secret.mgmt_local_admin_pwd.value // Created with the Libre DevOps Terraform Pre-Requisite script

  subnet_id            = element(values(module.network.subnets_ids), 0) // Places in sn1-vnet-ldo-euw-dev-01
  availability_zone    = "alternate"                                    // If more than 1 VM exists, places them in alterate zones, 1, 2, 3 then resetting.  If you want HA, use an availability set.
  storage_account_type = "Standard_LRS"
  identity_type        = "UserAssigned"
  identity_ids         = [data.azurerm_user_assigned_identity.mgmt_user_assigned_id.id]
}

// Don't want to use either? No problem.  Try this:
module "win_vm_with_custom_plan" {
  source = "registry.terraform.io/libre-devops/windows-vm/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location
  tags     = module.rg.rg_tags

  vm_amount   = 1
  vm_hostname = "app${var.short}${var.loc}${terraform.workspace}" // appldoeuwdev01
  vm_size     = "Standard_B2ms"

  use_simple_image_with_plan = false

  source_image_reference = {
    publisher = "center-for-internet-security-inc"
    offer     = "cis-windows-server-2016-v1-0-0-l2"
    sku       = "cis-ws2016-l2"
    version   = "latest"
  }

  plan = {
    name      = "cis-ws2016-l2"
    product   = "cis-windows-server-2016-v1-0-0-l2"
    publisher = "center-for-internet-security-inc"
  }

  vm_os_disk_size_gb = "127"

  asg_name = "asg-${element(regexall("[a-z]+", element(module.win_vm_with_plan.vm_name, 0)), 0)}-${var.short}-${var.loc}-${terraform.workspace}-01" //asg-vmldoeuwdev-ldo-euw-dev-01 - Regex strips all numbers from string

  admin_username = "LibreDevOpsAdmin"
  admin_password = data.azurerm_key_vault_secret.mgmt_local_admin_pwd.value // Created with the Libre DevOps Terraform Pre-Requisite script

  subnet_id            = element(values(module.network.subnets_ids), 0) // Places in sn1-vnet-ldo-euw-dev-01
  availability_zone    = "alternate"                                    // If more than 1 VM exists, places them in alterate zones, 1, 2, 3 then resetting.  If you want HA, use an availability set.
  storage_account_type = "Standard_LRS"
  identity_type        = "UserAssigned"
  identity_ids         = [data.azurerm_user_assigned_identity.mgmt_user_assigned_id.id]
}
