#!/bin/bash
# ================================================================================
# File: validate.sh
#
# Purpose:
#   Smoke-tests all seven Azure Cost MCP endpoints. Reads proxy credentials
#   from Key Vault, acquires a Bearer token as the proxy service principal,
#   then calls each route and checks for HTTP 200.
# ================================================================================

set -euo pipefail

# ================================================================================
# Read deployment outputs and credentials
# ================================================================================

echo "NOTE: Reading deployment outputs..."

cd 01-functions
KV_NAME=$(terraform output -raw key_vault_name)
FUNC_APP_URL=$(terraform output -raw function_app_url)
cd ..

echo "NOTE: Key vault:    ${KV_NAME}"
echo "NOTE: API base URL: ${FUNC_APP_URL}"

CLIENT_ID=$(az keyvault secret show \
  --vault-name "$KV_NAME" --name "proxy-client-id" --query value -o tsv)
CLIENT_SECRET=$(az keyvault secret show \
  --vault-name "$KV_NAME" --name "proxy-client-secret" --query value -o tsv)
TENANT_ID=$(az keyvault secret show \
  --vault-name "$KV_NAME" --name "proxy-tenant-id" --query value -o tsv)
API_CLIENT_ID=$(az keyvault secret show \
  --vault-name "$KV_NAME" --name "api-client-id" --query value -o tsv)

# ================================================================================
# Acquire Bearer token
# ================================================================================

echo "NOTE: Acquiring Bearer token..."

token_json=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials\
&client_id=${CLIENT_ID}\
&client_secret=${CLIENT_SECRET}\
&scope=${API_CLIENT_ID}/.default" \
  < /dev/null)

TOKEN=$(echo "$token_json" | jq -r '.access_token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to acquire token."
  echo "$token_json" | jq .
  exit 1
fi

echo "NOTE: Token acquired."

# ================================================================================
# Helper: call one endpoint and check for 200
# ================================================================================

call_api() {
  local method="$1" route="$2"
  local tmp_file http_code body wait=5

  tmp_file=$(mktemp)

  while true; do
    if [[ "$method" == "GET" ]]; then
      http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
        -X GET "${FUNC_APP_URL}/${route}" \
        -H "Authorization: Bearer ${TOKEN}" \
        < /dev/null)
    else
      http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
        -X POST "${FUNC_APP_URL}/${route}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{}" \
        < /dev/null)
    fi

    [[ "$http_code" != "429" ]] && break

    # Rate limited — back off and retry.
    echo "NOTE: Rate limited on ${method} /${route} — retrying in ${wait}s..."
    sleep "$wait"
    wait=$((wait * 2))
  done

  body=$(cat "$tmp_file")
  rm -f "$tmp_file"

  if [[ "$http_code" == "200" ]]; then
    echo "NOTE: OK  ${method} /${route}"
    if [[ "$route" == "tools" ]]; then
      echo "$body" | jq -r '.[] | "       \(.name)  →  \(.route)"'
    else
      echo "$body" | head -3 | sed 's/^/       /'
    fi
  else
    echo "ERROR: FAIL ${method} /${route} — HTTP ${http_code}"
    echo "  $body"
    exit 1
  fi
}

# ================================================================================
# Validate all endpoints
# ================================================================================

echo ""
echo "NOTE: Validating all endpoints..."
echo ""

call_api "GET"  "tools"
call_api "POST" "cost/month-to-date"
call_api "POST" "cost/by-service"
call_api "POST" "cost/compare-months"
call_api "POST" "cost/daily-trend"
call_api "POST" "cost/top-drivers"
call_api "POST" "cost/forecast"

echo ""
echo "========================================================================"
echo "  Validation complete — all 7 endpoints returned HTTP 200."
echo "========================================================================"
echo "  API: ${FUNC_APP_URL}"
echo "========================================================================"
