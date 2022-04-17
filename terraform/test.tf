module "rg" {
  source = "registry.terraform.io/libre-devops/rg/azurerm"

  rg_name    = "rg-${var.short}-${var.loc}-${terraform.workspace}"
  location   = local.location
  lock_level = "CanNotDelete"
  tags       = local.tags
}

module "network" {
  source = "registry.terraform.io/libre-devops/network/azurerm"

  rg_name  = module.rg.rg_name
  location = module.rg.rg_location

  vnet_name = "vnet-${var.short}-${var.loc}-${terraform.workspace}"
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