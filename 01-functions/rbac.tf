# Cost Management Reader on the subscription — grants the Function App's
# managed identity read access to cost data via DefaultAzureCredential.
resource "azurerm_role_assignment" "cost_reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_function_app_flex_consumption.cost_mcp.identity[0].principal_id
}
