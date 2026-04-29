# ================================================================================
# File: lambda-by-service.tf
# ================================================================================
# Purpose:
#   Deploys the "Cost by Service" Lambda function that breaks down MTD spend
#   by AWS service, sorted by cost descending.
#   Invoked via POST /cost/by-service.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_by_service_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_by_service_role" {
  name = "cost-by-service-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_by_service_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_by_service_basic" {
  role       = aws_iam_role.lambda_by_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_by_service_ce
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting read-only Cost Explorer access.
#   CE does not support resource-level permissions — resource must be "*".
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_by_service_ce" {
  name = "cost-by-service-ce"
  role = aws_iam_role.lambda_by_service_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:GetCostAndUsage"]
      Resource = ["*"]
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.lambda_by_service
# --------------------------------------------------------------------------------
# Description:
#   Deploys the cost-by-service Lambda. Returns MTD spend grouped by AWS
#   service as a plain-text summary sorted by cost descending.
#
# Handler:
#   costs.by_service_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_by_service" {
  function_name    = "cost-by-service"
  role             = aws_iam_role.lambda_by_service_role.arn
  runtime          = "python3.14"
  handler          = "costs.by_service_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
