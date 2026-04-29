# ================================================================================
# Key Vault
# Stores proxy credentials and pre-built Claude Desktop config JSONs so
# apply.sh can generate config files without any secret interpolation in shell.
# ================================================================================

resource "azurerm_key_vault" "rg_mcp" {
  name                       = "rg-mcp-kv-${random_id.suffix.hex}"
  location                   = azurerm_resource_group.rg_mcp.location
  resource_group_name        = azurerm_resource_group.rg_mcp.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# Grant the Terraform deployer full secrets access so it can write the secrets
# below and apply.sh can read them back via az keyvault secret show.
resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.rg_mcp.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "proxy_client_id" {
  name         = "proxy-client-id"
  value        = azuread_application.rg_mcp_proxy.client_id
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "proxy_client_secret" {
  name         = "proxy-client-secret"
  value        = azuread_application_password.rg_mcp_proxy.value
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "tenant_id" {
  name         = "proxy-tenant-id"
  value        = data.azurerm_client_config.current.tenant_id
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

# The API client ID is the token audience the proxy requests and the Function
# App validates. Stored here so validate.sh can acquire a token directly.
resource "azurerm_key_vault_secret" "api_client_id" {
  name         = "api-client-id"
  value        = azuread_application.rg_mcp_api.client_id
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "api_endpoint" {
  name         = "api-endpoint"
  value        = "https://${azurerm_function_app_flex_consumption.rg_mcp.default_hostname}/api"
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

# Full Claude Desktop config JSONs stored as single secrets — apply.sh reads
# these directly instead of stitching values together with envsubst.
resource "azurerm_key_vault_secret" "claude_config_ps1" {
  name  = "claude-desktop-config-ps1"
  value = jsonencode({
    mcpServers = {
      "azure-resource-mcp" = {
        command = "powershell"
        args    = ["-File", "REPLACE_WITH_ABSOLUTE_PATH\\azure-serverless-mcp\\02-proxy\\proxy.ps1"]
        env = {
          MCP_CLIENT_ID     = azuread_application.rg_mcp_proxy.client_id
          MCP_CLIENT_SECRET = azuread_application_password.rg_mcp_proxy.value
          MCP_TENANT_ID     = data.azurerm_client_config.current.tenant_id
          MCP_API_CLIENT_ID = azuread_application.rg_mcp_api.client_id
          MCP_API_ENDPOINT  = "https://${azurerm_function_app_flex_consumption.rg_mcp.default_hostname}/api"
        }
      }
    }
  })
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "claude_config_sh" {
  name  = "claude-desktop-config-sh"
  value = jsonencode({
    mcpServers = {
      "azure-resource-mcp" = {
        command = "bash"
        args    = ["REPLACE_WITH_ABSOLUTE_PATH/azure-serverless-mcp/02-proxy/proxy.sh"]
        env = {
          MCP_CLIENT_ID     = azuread_application.rg_mcp_proxy.client_id
          MCP_CLIENT_SECRET = azuread_application_password.rg_mcp_proxy.value
          MCP_TENANT_ID     = data.azurerm_client_config.current.tenant_id
          MCP_API_CLIENT_ID = azuread_application.rg_mcp_api.client_id
          MCP_API_ENDPOINT  = "https://${azurerm_function_app_flex_consumption.rg_mcp.default_hostname}/api"
        }
      }
    }
  })
  key_vault_id = azurerm_key_vault.rg_mcp.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}
