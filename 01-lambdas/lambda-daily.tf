# ================================================================================
# File: lambda-daily.tf
# ================================================================================
# Purpose:
#   Deploys the "Daily Cost Trend" Lambda function that returns day-by-day
#   spend for the current month with a running total column.
#   Invoked via POST /cost/daily-trend.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_daily_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_daily_role" {
  name = "cost-daily-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_daily_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_daily_basic" {
  role       = aws_iam_role.lambda_daily_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_daily_ce
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting read-only Cost Explorer access.
#   CE does not support resource-level permissions — resource must be "*".
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_daily_ce" {
  name = "cost-daily-ce"
  role = aws_iam_role.lambda_daily_role.id

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
# RESOURCE: aws_lambda_function.lambda_daily
# --------------------------------------------------------------------------------
# Description:
#   Deploys the daily-trend Lambda. Returns a DAILY-granularity cost query
#   for the current month with per-day amounts and running totals.
#
# Handler:
#   costs.daily_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_daily" {
  function_name    = "cost-daily"
  role             = aws_iam_role.lambda_daily_role.arn
  runtime          = "python3.14"
  handler          = "costs.daily_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
