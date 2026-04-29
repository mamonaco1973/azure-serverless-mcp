output "function_app_name" {
  value = azurerm_function_app_flex_consumption.cost_mcp.name
}

output "function_app_url" {
  value = "https://${azurerm_function_app_flex_consumption.cost_mcp.default_hostname}/api"
}

output "resource_group_name" {
  value = azurerm_resource_group.cost_mcp.name
}

output "key_vault_name" {
  value = azurerm_key_vault.cost_mcp.name
}
