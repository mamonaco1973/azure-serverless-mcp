# CLAUDE.md — aws-serverless-mcp

A serverless AWS Cost Explorer API designed for MCP (Model Context Protocol) tool use.
Seven Lambda functions expose cost query tools behind an API Gateway HTTP API with
AWS_IAM authorization. A local MCP proxy (`02-proxy/`) signs requests with SigV4,
making the remote serverless API transparent to the AI caller.

---

## What This Project Does

An AI assistant calls MCP tools that appear local but are backed by Lambda functions
running in AWS. Each tool queries the Cost Explorer API and returns a plain-text
summary suitable for direct narration — not raw CE JSON.

The proxy self-configures at startup by calling `GET /tools`, so route mappings and
tool schemas are defined once in `costs.py` with no hardcoding in the proxy.

**Base URL after deploy:**
```
https://{api-id}.execute-api.us-east-1.amazonaws.com
```

| Tool Name | Route | Lambda | Operation |
|-----------|-------|--------|-----------|
| *(proxy startup)* | `GET /tools` | cost-tools | Tool registry for proxy self-config |
| get_month_to_date_cost | `POST /cost/month-to-date` | cost-mtd | MTD total spend |
| get_cost_by_service | `POST /cost/by-service` | cost-by-service | Per-service breakdown |
| compare_this_month_to_last_month | `POST /cost/compare-months` | cost-compare | MoM delta |
| get_daily_cost_trend | `POST /cost/daily-trend` | cost-daily | Day-by-day spend |
| find_top_cost_drivers | `POST /cost/top-drivers` | cost-top-drivers | Ranked services |
| forecast_month_end_cost | `POST /cost/forecast` | cost-forecast | CE forecast |

---

## Architecture

```
AI assistant (MCP client)
     │  stdio / JSON-RPC
     ▼
02-proxy/proxy.sh (or proxy.ps1)  ← holds IAM credentials, signs with SigV4
     │  HTTPS + AWS_IAM auth
     ▼
API Gateway (HTTP API v2) — costs-api
     │  routes by method + path
     ├── GET  /tools               → Lambda: cost-tools  (proxy startup only)
     ├── POST /cost/month-to-date  → Lambda: cost-mtd
     ├── POST /cost/by-service     → Lambda: cost-by-service
     ├── POST /cost/compare-months → Lambda: cost-compare
     ├── POST /cost/daily-trend    → Lambda: cost-daily
     ├── POST /cost/top-drivers    → Lambda: cost-top-drivers
     └── POST /cost/forecast       → Lambda: cost-forecast
                │
                ▼
          AWS Cost Explorer API (global, us-east-1 endpoint)
```

**Why plain-text responses:** CE returns nested ResultsByTime arrays. Returning
pre-formatted summaries lets the AI narrate results without parsing, and keeps
the MCP tool contract simple.

**Why IAM auth:** The proxy signs every request with the caller's AWS credentials.
API Gateway enforces IAM authorization before the Lambda is invoked — no API keys
to rotate and no unauthenticated access possible.

**Why a tool-discovery route:** Adding a tool only requires updating `costs.py` and
redeploying — the proxy loads its route map from `GET /tools` at startup with no
hardcoded definitions.

---

## Repository Layout

```
01-lambdas/
  code/
    costs.py                  All seven handler functions (single file, single ZIP)
  main.tf                     Terraform: AWS provider, data sources, archive_file
  api.tf                      Terraform: HTTP API, 7 routes (AWS_IAM), integrations, stage
  lambda-tools.tf             Terraform: IAM role + Lambda for cost-tools (GET /tools)
  lambda-mtd.tf               Terraform: IAM role + Lambda for cost-mtd
  lambda-by-service.tf        Terraform: IAM role + Lambda for cost-by-service
  lambda-compare.tf           Terraform: IAM role + Lambda for cost-compare
  lambda-daily.tf             Terraform: IAM role + Lambda for cost-daily
  lambda-top-drivers.tf       Terraform: IAM role + Lambda for cost-top-drivers
  lambda-forecast.tf          Terraform: IAM role + Lambda for cost-forecast
  iam-proxy-user.tf           Terraform: IAM user + access key + Secrets Manager secret
02-proxy/
  proxy.sh                    Bash MCP stdio proxy (SigV4 signing, JSON-RPC dispatcher)
  proxy.ps1                   PowerShell equivalent of proxy.sh
  claude_desktop_config_sh.json.tmpl   Claude Desktop config template (bash proxy)
  claude_desktop_config_ps1.json.tmpl  Claude Desktop config template (PowerShell proxy)
check_env.sh                  Pre-flight: verify aws/terraform/jq, test AWS credentials
apply.sh                      Full deployment + config generation + validation
destroy.sh                    Teardown
validate.sh                   Smoke test via direct Lambda invocation (bypasses IAM auth)
```

---

## Prerequisites

- `aws`, `terraform`, `jq`, `envsubst` in PATH
- `bash 4+`, `curl`, `openssl` (for `proxy.sh`)
- AWS credentials configured with permissions:
  - Lambda, API Gateway, IAM, Secrets Manager (for deploy)
  - `ce:GetCostAndUsage`, `ce:GetCostForecast` (for the Lambda execution roles)
- Cost Explorer must be enabled in the AWS account (Console → Billing → Cost Explorer)

---

## Deployment

```bash
# Full deploy
./apply.sh

# Teardown
./destroy.sh

# Smoke test only (after deploy)
./validate.sh
```

`apply.sh` runs in one sequence:
1. **`check_env.sh`** → validates tools and AWS credentials
2. **`01-lambdas`** → deploys all seven Lambdas, API Gateway, IAM roles, IAM proxy
   user, and Secrets Manager secret
3. **Config generation** → fetches proxy credentials from Secrets Manager and runs
   `envsubst` to produce `02-proxy/claude_desktop_config_*.json` (gitignored)
4. **`validate.sh`** → invokes each Lambda directly and prints the plain-text output

---

## Terraform Modules

### 01-lambdas
- Seven `aws_lambda_function` resources (Python 3.14, 15s timeout), one per tool
- Seven `aws_iam_role` resources with scoped CE policies (least-privilege per tool):
  - `ce:GetCostAndUsage` for mtd, by-service, compare, daily, top-drivers
  - `ce:GetCostForecast` for forecast (separate action)
  - No CE permissions for cost-tools (returns static registry data only)
- `aws_apigatewayv2_api` `costs-api` — HTTP API (no CORS, IAM auth only)
- Seven `aws_apigatewayv2_integration` + `aws_apigatewayv2_route` pairs
- All routes: `authorization_type = "AWS_IAM"`
- `aws_apigatewayv2_stage` `$default` with auto_deploy
- Seven `aws_lambda_permission` resources granting API Gateway invoke rights
- `aws_iam_user` `cost-mcp-proxy` with inline `execute-api:Invoke` policy scoped
  to this API's execution ARN
- `aws_iam_access_key` for the proxy user
- `aws_secretsmanager_secret` `cost-mcp-proxy` storing access key ID, secret access
  key, API endpoint, and region as a JSON object

---

## Lambda Code

All seven handlers live in `costs.py` and follow the same pattern:
- Compute date windows using `datetime` and `calendar.monthrange`
- Call `boto3.client("ce", region_name="us-east-1")` — CE endpoint is always us-east-1
- Return `{"statusCode": 200, "headers": {"Content-Type": "text/plain"}, "body": "..."}`
- Body is a human-readable plain-text summary, not raw CE JSON
- Handle `DataUnavailableException` from `GetCostForecast` gracefully

The `tools_handler` is the exception — it returns `Content-Type: application/json`
with the `TOOL_REGISTRY` array (name, description, inputSchema, route per tool).

**CE date range convention:**
- Start is inclusive, end is exclusive
- MTD queries use end = tomorrow to capture today's partial data
- Full-month queries use end = first day of next month

---

## MCP Proxy

`02-proxy/proxy.sh` (and `proxy.ps1` for Windows) is a stdio MCP server:
- Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout
- On startup calls `GET /tools` (SigV4 signed) to populate its route map and tool list
- Signs all API Gateway requests with AWS SigV4 using credentials from env vars
- Handles `initialize`, `tools/list`, and `tools/call` methods

Required environment variables (populated by the generated config files):
```
MCP_ACCESS_KEY_ID      IAM access key for the cost-mcp-proxy user
MCP_SECRET_ACCESS_KEY  IAM secret key for the cost-mcp-proxy user
MCP_API_ENDPOINT       API Gateway invoke URL (no trailing slash)
MCP_REGION             AWS region (default: us-east-1)
```

After `./apply.sh`, copy the contents of `02-proxy/claude_desktop_config_sh.json`
(Linux/macOS) or `02-proxy/claude_desktop_config_ps1.json` (Windows) into your
Claude Desktop `claude_desktop_config.json`.

---

## Test Manually

```bash
# Invoke any tool directly (no SigV4 needed for direct Lambda calls)
aws lambda invoke \
  --function-name cost-mtd \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/out.json && jq -r '.body' /tmp/out.json

# Via API Gateway (requires SigV4 signing — use awscurl or the MCP proxy)
awscurl --service execute-api --region us-east-1 \
  -X POST https://{api-id}.execute-api.us-east-1.amazonaws.com/cost/month-to-date
```
