# CLAUDE.md — azure-serverless-mcp

A serverless Azure Cost Management API designed for MCP (Model Context Protocol)
tool use. Six Azure Functions expose cost query tools behind an HTTP API secured
with service-principal Bearer tokens. A local MCP proxy acquires tokens from
Azure AD and makes the remote serverless backend transparent to the AI caller.

---

## What This Project Does

An AI assistant calls MCP tools that appear local but are backed by Azure
Functions querying the Azure Cost Management API. Responses are plain-text
summaries suitable for direct narration — not raw JSON.

The proxy self-configures at startup by calling `GET /tools`, so route
mappings and tool schemas are defined once in `function_app.py` with no
hardcoding in the proxy.

**Base URL after deploy:**
```
https://{func-app}.azurewebsites.net/api
```

| Tool Name | Route | Operation |
|---|---|---|
| *(proxy startup)* | `GET /tools` | Tool registry for proxy self-config |
| get_month_to_date_cost | `POST /cost/month-to-date` | MTD total spend |
| get_cost_by_service | `POST /cost/by-service` | Per-service breakdown |
| compare_this_month_to_last_month | `POST /cost/compare-months` | MoM delta |
| get_daily_cost_trend | `POST /cost/daily-trend` | Day-by-day spend |
| find_top_cost_drivers | `POST /cost/top-drivers` | Ranked services |
| forecast_month_end_cost | `POST /cost/forecast` | Month-end projection |

---

## Architecture

```
AI assistant (MCP client)
     │  stdio / JSON-RPC
     ▼
02-proxy/proxy.sh (or proxy.ps1)
  ├─ Acquires Bearer token from Azure AD (client_credentials flow)
  └─ Sends Authorization: Bearer <token> on every request
     │  HTTPS + Bearer auth
     ▼
Azure Functions (cost-mcp-func-xxxx.azurewebsites.net/api)
  ├─ Validates JWT in-code against Azure AD JWKS
  ├─ GET  /tools               → TOOL_REGISTRY JSON (proxy startup only)
  ├─ POST /cost/month-to-date  → MTD total
  ├─ POST /cost/by-service     → grouped by ServiceName
  ├─ POST /cost/compare-months → this month vs last month
  ├─ POST /cost/daily-trend    → per-day with running total
  ├─ POST /cost/top-drivers    → top 10 services ranked
  └─ POST /cost/forecast       → remaining + projected total
       │
       │  DefaultAzureCredential (Managed Identity)
       ▼
  Azure Cost Management API
  scope: /subscriptions/{subscription_id}
```

**Auth layers:**
1. Proxy acquires a token for `{api_client_id}/.default` via client credentials
2. Function App validates token signature (Azure AD JWKS), audience, and expiry
3. Function App's Managed Identity calls Cost Management with no credentials in
   code — RBAC role `Cost Management Reader` assigned at subscription scope

**Why plain-text responses:** Cost Management returns nested JSON. Returning
pre-formatted summaries lets the AI narrate results without parsing.

**Why in-code JWT validation:** `azurerm_function_app_flex_consumption` (FC1)
does not support the `auth_settings_v2` Easy Auth block. Token validation in
Python is equivalent security — same checks, same rejection on bad tokens.

---

## Repository Layout

```
01-functions/
  code/
    function_app.py     All seven handlers + JWT validation + Cost Mgmt client
    host.json           Extension bundle v4
    requirements.txt    azure-functions, azure-mgmt-costmanagement, azure-identity,
                        PyJWT, cryptography, requests
  main.tf               azurerm + azuread + random providers, resource group
  entra.tf              Two Entra app registrations + service principal password
  keyvault.tf           Key Vault (RBAC) + five secrets for proxy config
  functions.tf          Storage, FC1 service plan, Function App, Managed Identity
  rbac.tf               Cost Management Reader on subscription for Managed Identity
  outputs.tf            function_app_name, function_app_url, resource_group_name,
                        key_vault_name
02-proxy/
  proxy.sh              Bash MCP stdio proxy (Bearer token, JSON-RPC dispatcher)
  proxy.ps1             PowerShell equivalent of proxy.sh
  claude_desktop_config_sh.json.tmpl   Claude Desktop config template (bash)
  claude_desktop_config_ps1.json.tmpl  Claude Desktop config template (PowerShell)
check_env.sh            Pre-flight: verify az/terraform/jq/zip/envsubst + ARM_ vars
apply.sh                Full deployment + config generation + validation
destroy.sh              Teardown
validate.sh             Acquires token, calls all 7 endpoints, checks HTTP 200
```

---

## Prerequisites

- `az`, `terraform`, `jq`, `zip`, `envsubst` in PATH
- Azure subscription with Cost Management enabled
- Service principal with Contributor (or scoped) rights for Terraform deployment
- Environment variables:
  ```
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_SUBSCRIPTION_ID
  ARM_TENANT_ID
  ```

---

## Deployment

```bash
./apply.sh   # full deploy
./destroy.sh # teardown
./validate.sh # smoke test (after deploy)
```

`apply.sh` runs in sequence:
1. **`check_env.sh`** — validates tools and Azure credentials
2. **`01-functions` Terraform** — deploys Function App, Entra registrations,
   Key Vault, Managed Identity, RBAC role assignment
3. **Code deploy** — zips `01-functions/code/` and pushes via
   `az functionapp deployment source config-zip --build-remote true`
4. **Config generation** — reads five secrets from Key Vault, runs `envsubst`
   to produce `02-proxy/claude_desktop_config_*.json` (gitignored)
5. **`validate.sh`** — acquires a Bearer token and calls all 7 endpoints

---

## Terraform Resources

### 01-functions

- `azurerm_resource_group` `cost-mcp-rg`
- `azuread_application` `cost-mcp-api` — API app registration (token audience)
- `azuread_application` `cost-mcp-proxy` — proxy service principal
- `azuread_application_password` — client secret for proxy SP (stored in KV)
- `azurerm_key_vault` `cost-mcp-kv-{suffix}` — RBAC-mode, soft-delete 7 days
- 5x `azurerm_key_vault_secret` — proxy-client-id, proxy-client-secret,
  proxy-tenant-id, api-client-id, api-endpoint
- `azurerm_storage_account` `costmcpfunc{suffix}` — Function App code storage
- `azurerm_service_plan` `cost-mcp-plan` — Linux FC1 (Flex Consumption)
- `azurerm_application_insights` `cost-mcp-ai`
- `azurerm_function_app_flex_consumption` `cost-mcp-func-{suffix}` —
  Python 3.11, SystemAssigned identity, 10 max instances
- `azurerm_role_assignment` — `Cost Management Reader` on subscription for
  the Function App's managed identity principal

---

## Function Code

All seven handlers live in `function_app.py` and follow the same pattern:
1. `_validate_token(req)` — verifies Bearer JWT (signature + audience + expiry)
2. `_audit_log(req, tool)` — logs tool name and `x-mcp-user` header
3. Call `CostManagementClient.query.usage()` (or `.forecast.usage()`) via
   `DefaultAzureCredential` (resolves to Managed Identity at runtime)
4. Parse result columns by name (`_col_idx`) — column order is not guaranteed
5. Return plain-text `func.HttpResponse`

**Cost Management scope:** `/subscriptions/{SUBSCRIPTION_ID}` (env var)

**Date convention:** Custom timeframe with `from_property` (inclusive) / `to`
(exclusive). MTD end = tomorrow to capture today's partial data. Same pattern
as the AWS version; Azure CM uses identical open-interval semantics.

**Forecast:** Queries remaining days of the month, then adds actual MTD to
produce a projected month-end total. `include_actual_cost=False` returns only
the forecast portion.

---

## MCP Proxy

`02-proxy/proxy.sh` (and `proxy.ps1` for Windows) is a stdio MCP server:
- Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout
- On startup, acquires a Bearer token, then calls `GET /tools` to populate
  route map and tool list
- Caches the token; re-acquires 60 s before expiry
- Handles `initialize`, `tools/list`, and `tools/call` methods

Required environment variables (written into the generated config files):
```
MCP_CLIENT_ID      Proxy service principal client ID
MCP_CLIENT_SECRET  Proxy service principal client secret
MCP_TENANT_ID      Azure AD tenant ID
MCP_API_CLIENT_ID  API app client ID (used as token scope: {id}/.default)
MCP_API_ENDPOINT   Function App URL (no trailing slash)
```

After `./apply.sh`, copy the relevant config file contents into your Claude
Desktop `claude_desktop_config.json` and update the proxy script path.

---

## Manual Testing

```bash
# Read outputs
cd 01-functions
KV=$(terraform output -raw key_vault_name)
URL=$(terraform output -raw function_app_url)
cd ..

# Acquire token
CLIENT_ID=$(az keyvault secret show --vault-name $KV --name proxy-client-id --query value -o tsv)
SECRET=$(az keyvault secret show --vault-name $KV --name proxy-client-secret --query value -o tsv)
TENANT=$(az keyvault secret show --vault-name $KV --name proxy-tenant-id --query value -o tsv)
API_CLIENT=$(az keyvault secret show --vault-name $KV --name api-client-id --query value -o tsv)

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${SECRET}&scope=${API_CLIENT}/.default" \
  | jq -r '.access_token')

# Call an endpoint
curl -s -X POST "${URL}/cost/month-to-date" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{}"
```
