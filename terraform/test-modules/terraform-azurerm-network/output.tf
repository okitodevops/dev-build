output "subnets_name_to_id" {
  value = {
  for index, subnet in azurerm_subnet.subnet :
  subnet.name => subnet.id
  }
}