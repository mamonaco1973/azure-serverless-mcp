resource "azurerm_storage_account" "functions" {
  name                     = "rgmcpfunc${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.rg_mcp.name
  location                 = azurerm_resource_group.rg_mcp.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "func_code" {
  name                  = "func-code"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "rg_mcp" {
  name                = "rg-mcp-plan"
  resource_group_name = azurerm_resource_group.rg_mcp.name
  location            = azurerm_resource_group.rg_mcp.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_application_insights" "rg_mcp" {
  name                = "rg-mcp-ai"
  resource_group_name = azurerm_resource_group.rg_mcp.name
  location            = azurerm_resource_group.rg_mcp.location
  application_type    = "web"
}

resource "azurerm_function_app_flex_consumption" "rg_mcp" {
  name                = "rg-mcp-func-${random_id.suffix.hex}"
  resource_group_name = azurerm_resource_group.rg_mcp.name
  location            = azurerm_resource_group.rg_mcp.location

  service_plan_id = azurerm_service_plan.rg_mcp.id
  https_only      = true

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.func_code.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.functions.primary_access_key

  runtime_name    = "python"
  runtime_version = "3.11"

  maximum_instance_count = 10
  instance_memory_in_mb  = 2048

  site_config {}

  # System-assigned identity used by the function code to query Resource Graph
  # via DefaultAzureCredential — no credentials in app settings.
  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    FUNCTIONS_EXTENSION_VERSION           = "~4"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.rg_mcp.connection_string
    AzureWebJobsFeatureFlags              = "EnableWorkerIndexing"
    SUBSCRIPTION_ID                       = data.azurerm_client_config.current.subscription_id
    # Used by in-code JWT validation to verify token audience and issuer.
    API_CLIENT_ID                         = azuread_application.rg_mcp_api.client_id
    TENANT_ID                             = data.azurerm_client_config.current.tenant_id
  }

  lifecycle {
    ignore_changes = [
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      app_settings["FUNCTIONS_EXTENSION_VERSION"],
      app_settings["SCM_DO_BUILD_DURING_DEPLOYMENT"],
      site_config,
    ]
  }
}
