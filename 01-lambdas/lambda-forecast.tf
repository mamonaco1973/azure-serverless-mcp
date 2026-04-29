# ================================================================================
# File: lambda-forecast.tf
# ================================================================================
# Purpose:
#   Deploys the "Month-End Forecast" Lambda function that projects remaining
#   AWS spend through the last day of the current month with a confidence
#   interval.
#   Invoked via POST /cost/forecast.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_forecast_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_forecast_role" {
  name = "cost-forecast-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_forecast_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_forecast_basic" {
  role       = aws_iam_role.lambda_forecast_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_forecast_ce
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting Cost Explorer forecast access.
#   ce:GetCostForecast is a separate action from GetCostAndUsage.
#   CE does not support resource-level permissions — resource must be "*".
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_forecast_ce" {
  name = "cost-forecast-ce"
  role = aws_iam_role.lambda_forecast_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:GetCostForecast"]
      Resource = ["*"]
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.lambda_forecast
# --------------------------------------------------------------------------------
# Description:
#   Deploys the forecast Lambda. Calls GetCostForecast from today through
#   end of month and returns a plain-text summary with an 80% confidence range.
#
# Handler:
#   costs.forecast_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_forecast" {
  function_name    = "cost-forecast"
  role             = aws_iam_role.lambda_forecast_role.arn
  runtime          = "python3.14"
  handler          = "costs.forecast_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
