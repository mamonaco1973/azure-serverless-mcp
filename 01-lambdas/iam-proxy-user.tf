# ================================================================================
# File: iam-proxy-user.tf
# ================================================================================
# Purpose:
#   Creates a dedicated IAM user for the MCP proxy with the minimum permission
#   needed to call the Cost Explorer API Gateway endpoints. The generated access
#   key pair is stored in Secrets Manager as the authoritative credential source
#   for the proxy at runtime.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_user.mcp_proxy
# --------------------------------------------------------------------------------
# Description:
#   Dedicated IAM user for the MCP proxy. Scoped to API invocation only —
#   no console access, no other AWS permissions.
# --------------------------------------------------------------------------------
resource "aws_iam_user" "mcp_proxy" {
  name = "cost-mcp-proxy"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_user_policy.mcp_proxy_invoke
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting execute-api:Invoke on this specific API only.
#   The execution ARN includes the API ID, scoping access to costs-api
#   and no other API Gateway in the account.
# --------------------------------------------------------------------------------
resource "aws_iam_user_policy" "mcp_proxy_invoke" {
  name = "cost-mcp-proxy-invoke"
  user = aws_iam_user.mcp_proxy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["execute-api:Invoke"]
      Resource = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_access_key.mcp_proxy_key
# --------------------------------------------------------------------------------
# Description:
#   Programmatic access key for the proxy user. The secret access key is
#   only available at creation time — Secrets Manager is the durable store.
# --------------------------------------------------------------------------------
resource "aws_iam_access_key" "mcp_proxy_key" {
  user = aws_iam_user.mcp_proxy.name
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_secretsmanager_secret.mcp_proxy_credentials
# --------------------------------------------------------------------------------
# Description:
#   Named secret that holds the proxy IAM credentials. The proxy fetches
#   this secret at runtime to sign API Gateway requests with SigV4.
# --------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "mcp_proxy_credentials" {
  name                    = "cost-mcp-proxy"
  description             = "IAM credentials for the Cost Explorer MCP proxy user"
  recovery_window_in_days = 0 # Allow immediate delete on terraform destroy
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_secretsmanager_secret_version.mcp_proxy_credentials
# --------------------------------------------------------------------------------
# Description:
#   Stores the access key ID and secret access key as a JSON object so the
#   proxy can fetch both values in a single Secrets Manager call.
# --------------------------------------------------------------------------------
resource "aws_secretsmanager_secret_version" "mcp_proxy_credentials" {
  secret_id = aws_secretsmanager_secret.mcp_proxy_credentials.id

  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.mcp_proxy_key.id
    secret_access_key = aws_iam_access_key.mcp_proxy_key.secret
    api_endpoint      = aws_apigatewayv2_stage.costs_stage.invoke_url
    region            = data.aws_region.current.id
  })
}
