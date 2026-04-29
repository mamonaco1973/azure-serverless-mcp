#!/bin/bash
# ================================================================================
# File: validate.sh
#
# Purpose:
#   Smoke-tests all six Cost Explorer MCP Lambda functions by invoking them
#   directly via the AWS CLI.
#
# Notes:
#   - API Gateway routes require AWS_IAM authorization (SigV4 signing).
#     Direct Lambda invocation bypasses API Gateway auth and is used here
#     so validation works without a separately configured MCP proxy.
#   - All functions take no input — the payload is an empty JSON object.
#   - A non-200 statusCode in the Lambda response is treated as a failure.
# ================================================================================

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------

export AWS_DEFAULT_REGION="us-east-1"

# Enable strict shell behavior.
set -euo pipefail

# Temporary file for Lambda response payloads.
RESPONSE_FILE="/tmp/lambda_response.json"

# ------------------------------------------------------------------------------
# Helper: invoke and print
# ------------------------------------------------------------------------------

# Invokes a Lambda function, prints its plain-text body, and fails if the
# returned statusCode is not 200.
invoke_tool() {
  local fn_name="$1"
  local label="$2"

  echo ""
  echo "NOTE: Invoking ${label} (${fn_name})..."

  aws lambda invoke \
    --function-name "${fn_name}" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    "${RESPONSE_FILE}" > /dev/null

  # Extract statusCode and body from the Lambda response envelope.
  local status
  status=$(jq -r '.statusCode' "${RESPONSE_FILE}")

  local body
  body=$(jq -r '.body' "${RESPONSE_FILE}")

  if [[ "${status}" != "200" ]]; then
    echo "ERROR: ${label} returned HTTP ${status}:"
    echo "  ${body}"
    exit 1
  fi

  echo "${body}"
}

# ------------------------------------------------------------------------------
# Step 1: Tool discovery registry
# ------------------------------------------------------------------------------

echo ""
echo "NOTE: Invoking tool registry (cost-tools)..."

aws lambda invoke \
  --function-name "cost-tools" \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  "${RESPONSE_FILE}" > /dev/null

TOOLS_STATUS=$(jq -r '.statusCode' "${RESPONSE_FILE}")
TOOLS_BODY=$(jq -r '.body' "${RESPONSE_FILE}")

if [[ "${TOOLS_STATUS}" != "200" ]]; then
  echo "ERROR: cost-tools returned HTTP ${TOOLS_STATUS}:"
  echo "  ${TOOLS_BODY}"
  exit 1
fi

TOOL_COUNT=$(echo "${TOOLS_BODY}" | jq 'length')
echo "Registry contains ${TOOL_COUNT} tool(s):"
echo "${TOOLS_BODY}" | jq -r '.[] | "  \(.name) → \(.route)"'

# ------------------------------------------------------------------------------
# Step 2: Month-to-date total
# ------------------------------------------------------------------------------

invoke_tool "cost-mtd" "get_month_to_date_cost"

# ------------------------------------------------------------------------------
# Step 3: Cost by service
# ------------------------------------------------------------------------------

invoke_tool "cost-by-service" "get_cost_by_service"

# ------------------------------------------------------------------------------
# Step 4: Month-over-month comparison
# ------------------------------------------------------------------------------

invoke_tool "cost-compare" "compare_this_month_to_last_month"

# ------------------------------------------------------------------------------
# Step 5: Daily cost trend
# ------------------------------------------------------------------------------

invoke_tool "cost-daily" "get_daily_cost_trend"

# ------------------------------------------------------------------------------
# Step 6: Top cost drivers
# ------------------------------------------------------------------------------

invoke_tool "cost-top-drivers" "find_top_cost_drivers"

# ------------------------------------------------------------------------------
# Step 7: Month-end forecast
# ------------------------------------------------------------------------------

invoke_tool "cost-forecast" "forecast_month_end_cost"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='costs-api'].ApiId" \
  --output text)

API_BASE=""
if [[ -n "${API_ID}" && "${API_ID}" != "None" ]]; then
  API_BASE=$(aws apigatewayv2 get-api \
    --api-id "${API_ID}" \
    --query "ApiEndpoint" \
    --output text)
fi

echo ""
echo "========================================================================"
echo "  Validation complete — tool discovery + all six MCP cost tools OK."
echo "========================================================================"
if [[ -n "${API_BASE}" ]]; then
  echo "  API endpoint: ${API_BASE}"
  echo "  Auth: AWS_IAM (SigV4 required for all routes)"
fi
echo "========================================================================"

# ================================================================================
# End of script
# ================================================================================
