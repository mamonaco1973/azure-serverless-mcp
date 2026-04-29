#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the Azure Cost MCP API stack:
#   environment validation → Terraform (infra + Entra + Key Vault) →
#   function code deploy → Claude Desktop config generation → validation.
# ================================================================================

set -euo pipefail

# ================================================================================
# Environment pre-check
# ================================================================================

echo "NOTE: Running environment validation..."
./check_env.sh

# ================================================================================
# Deploy infrastructure
# ================================================================================

echo "NOTE: Deploying Azure Functions infrastructure..."

cd 01-functions
terraform init -upgrade
terraform apply -auto-approve

RESOURCE_GROUP=$(terraform output -raw resource_group_name)
FUNC_APP_NAME=$(terraform output -raw function_app_name)
KV_NAME=$(terraform output -raw key_vault_name)
FUNC_APP_URL=$(terraform output -raw function_app_url)
cd ..

echo "NOTE: Resource group: ${RESOURCE_GROUP}"
echo "NOTE: Function app:   ${FUNC_APP_NAME}"
echo "NOTE: Key vault:      ${KV_NAME}"

# ================================================================================
# Deploy function code
# ================================================================================

echo "NOTE: Packaging and deploying function code..."

cd 01-functions/code
rm -f app.zip
zip -r app.zip . \
  -x "*__pycache__*" \
  -x "*.pyc" \
  -x "*.DS_Store"

az functionapp deployment source config-zip \
  --name           "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src            app.zip \
  --build-remote   true

rm -f app.zip
cd ../..

# ================================================================================
# Generate Claude Desktop MCP config
# ================================================================================

# Config JSONs are built by Terraform with all secrets embedded and stored in
# Key Vault as single secrets. Read them out directly — no envsubst needed.
echo "NOTE: Reading Claude Desktop configs from Key Vault..."

az keyvault secret show \
  --vault-name "$KV_NAME" --name "claude-desktop-config-ps1" \
  --query value -o tsv > 02-proxy/claude_desktop_config_ps1.json

az keyvault secret show \
  --vault-name "$KV_NAME" --name "claude-desktop-config-sh" \
  --query value -o tsv > 02-proxy/claude_desktop_config_sh.json

echo "NOTE: Configs written to 02-proxy/claude_desktop_config_ps1.json"
echo "NOTE:                 and 02-proxy/claude_desktop_config_sh.json"

# ================================================================================
# Post-deployment validation
# ================================================================================

echo "NOTE: Running post-deployment validation..."
./validate.sh

echo ""
echo "NOTE: Deployment complete."
echo "NOTE: API: ${FUNC_APP_URL}"
