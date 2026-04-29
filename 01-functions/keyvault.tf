# ================================================================================
# Key Vault
# Stores proxy credentials so apply.sh can generate Claude Desktop config
# without embedding secrets in templates or Terraform outputs.
# ================================================================================

resource "azurerm_key_vault" "cost_mcp" {
  name                      = "cost-mcp-kv-${random_id.suffix.hex}"
  location                  = azurerm_resource_group.cost_mcp.location
  resource_group_name       = azurerm_resource_group.cost_mcp.name
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# Grant the Terraform deployer full secrets access so it can write the secrets
# below and apply.sh can read them back via az keyvault secret show.
resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.cost_mcp.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "proxy_client_id" {
  name         = "proxy-client-id"
  value        = azuread_application.cost_mcp_proxy.client_id
  key_vault_id = azurerm_key_vault.cost_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "proxy_client_secret" {
  name         = "proxy-client-secret"
  value        = azuread_application_password.cost_mcp_proxy.value
  key_vault_id = azurerm_key_vault.cost_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "tenant_id" {
  name         = "proxy-tenant-id"
  value        = data.azurerm_client_config.current.tenant_id
  key_vault_id = azurerm_key_vault.cost_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

# The API client ID is the token audience the proxy requests and the Function
# App validates. Stored here so apply.sh can write it into the proxy config.
resource "azurerm_key_vault_secret" "api_client_id" {
  name         = "api-client-id"
  value        = azuread_application.cost_mcp_api.client_id
  key_vault_id = azurerm_key_vault.cost_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "api_endpoint" {
  name         = "api-endpoint"
  value        = "https://${azurerm_function_app_flex_consumption.cost_mcp.default_hostname}/api"
  key_vault_id = azurerm_key_vault.cost_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}
