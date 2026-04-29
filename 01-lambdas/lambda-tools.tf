# ================================================================================
# File: lambda-tools.tf
# ================================================================================
# Purpose:
#   Deploys the tool discovery Lambda that returns the MCP tool registry.
#   Invoked via GET /tools by the proxy at startup to self-configure its
#   route map and tool schema list without any hardcoded definitions.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_tools_role
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_tools_role" {
  name = "cost-tools-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy_attachment.lambda_tools_basic
# --------------------------------------------------------------------------------
# No Cost Explorer permissions needed — this handler only returns static data.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_tools_basic" {
  role       = aws_iam_role.lambda_tools_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.lambda_tools
# --------------------------------------------------------------------------------
# Description:
#   Returns the TOOL_REGISTRY from costs.py as a JSON array. Used by the
#   proxy on startup so route mappings and tool schemas stay in one place.
#
# Handler:
#   costs.tools_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_tools" {
  function_name    = "cost-tools"
  role             = aws_iam_role.lambda_tools_role.arn
  runtime          = "python3.14"
  handler          = "costs.tools_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
