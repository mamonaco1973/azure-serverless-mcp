# ================================================================================
# File: api.tf
# ================================================================================
# Purpose:
#   Provides Cost Explorer query endpoints for the MCP serverless API:
#     - GET  /tools                → Tool registry for proxy self-configuration
#     - POST /cost/month-to-date   → Month-to-date total spend
#     - POST /cost/by-service      → Spend broken down by AWS service
#     - POST /cost/compare-months  → This month vs last month
#     - POST /cost/daily-trend     → Daily spend for current month
#     - POST /cost/top-drivers     → Top 10 cost drivers by spend
#     - POST /cost/forecast        → End-of-month cost forecast
#
# Notes:
#   - Uses HTTP API (v2) for cost efficiency and low-latency routing.
#   - All routes require AWS_IAM authorization — callers must sign
#     requests with SigV4. This is the core security mechanism that
#     the MCP proxy layer will use when invoking these tools.
#   - All routes use POST so the MCP proxy can pass a JSON body for
#     future parameter support without a route redesign.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_api.costs_api
# --------------------------------------------------------------------------------
# Description:
#   Creates the HTTP API that exposes the Cost Explorer MCP endpoints.
#   No CORS is configured — IAM-signed server-side callers do not need it.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "costs_api" {
  name          = "costs-api"
  protocol_type = "HTTP"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_integration — one per Lambda
# --------------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "tools_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_tools.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "mtd_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_mtd.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "by_service_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_by_service.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "compare_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_compare.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "daily_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_daily.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "top_drivers_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_top_drivers.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "forecast_integration" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_forecast.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_route — one per tool endpoint
# --------------------------------------------------------------------------------
# All routes use AWS_IAM authorization so the MCP proxy must sign every
# request with SigV4. Unsigned calls are rejected by API Gateway before
# reaching the Lambda function.
# --------------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "tools_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "GET /tools"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.tools_integration.id}"
}

resource "aws_apigatewayv2_route" "mtd_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/month-to-date"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.mtd_integration.id}"
}

resource "aws_apigatewayv2_route" "by_service_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/by-service"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.by_service_integration.id}"
}

resource "aws_apigatewayv2_route" "compare_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/compare-months"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.compare_integration.id}"
}

resource "aws_apigatewayv2_route" "daily_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/daily-trend"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.daily_integration.id}"
}

resource "aws_apigatewayv2_route" "top_drivers_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/top-drivers"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.top_drivers_integration.id}"
}

resource "aws_apigatewayv2_route" "forecast_route" {
  api_id             = aws_apigatewayv2_api.costs_api.id
  route_key          = "POST /cost/forecast"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.forecast_integration.id}"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_stage.costs_stage
# --------------------------------------------------------------------------------
# Description:
#   Creates the default stage for automatic API deployment.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_stage" "costs_stage" {
  api_id      = aws_apigatewayv2_api.costs_api.id
  name        = "$default"
  auto_deploy = true
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_permission — one per Lambda
# --------------------------------------------------------------------------------
# Grants API Gateway permission to invoke each Lambda function.
# --------------------------------------------------------------------------------

resource "aws_lambda_permission" "allow_tools_invoke" {
  statement_id  = "AllowAPIGatewayInvokeTools"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_tools.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_mtd_invoke" {
  statement_id  = "AllowAPIGatewayInvokeMtd"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_mtd.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_by_service_invoke" {
  statement_id  = "AllowAPIGatewayInvokeByService"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_by_service.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_compare_invoke" {
  statement_id  = "AllowAPIGatewayInvokeCompare"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_compare.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_daily_invoke" {
  statement_id  = "AllowAPIGatewayInvokeDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_daily.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_top_drivers_invoke" {
  statement_id  = "AllowAPIGatewayInvokeTopDrivers"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_top_drivers.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_forecast_invoke" {
  statement_id  = "AllowAPIGatewayInvokeForecast"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_forecast.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

# # --------------------------------------------------------------------------------
# # OUTPUT: costs_api_endpoint (optional)
# # --------------------------------------------------------------------------------
# output "costs_api_endpoint" {
#   description = "Invoke URL for the Cost Explorer MCP API"
#   value       = aws_apigatewayv2_stage.costs_stage.invoke_url
# }
