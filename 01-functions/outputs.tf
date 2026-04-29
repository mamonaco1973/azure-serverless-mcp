output "function_app_name" {
  value = azurerm_function_app_flex_consumption.rg_mcp.name
}

output "function_app_url" {
  value = "https://${azurerm_function_app_flex_consumption.rg_mcp.default_hostname}/api"
}

output "resource_group_name" {
  value = azurerm_resource_group.rg_mcp.name
}

output "key_vault_name" {
  value = azurerm_key_vault.rg_mcp.name
}
