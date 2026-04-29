# ================================================================================
# File: lambda-top-drivers.tf
# ================================================================================
# Purpose:
#   Deploys the "Top Cost Drivers" Lambda function that returns the ten
#   highest-spending AWS services for the current month with spend share.
#   Invoked via POST /cost/top-drivers.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_top_drivers_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_top_drivers_role" {
  name = "cost-top-drivers-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_top_drivers_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_top_drivers_basic" {
  role       = aws_iam_role.lambda_top_drivers_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_top_drivers_ce
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting read-only Cost Explorer access.
#   CE does not support resource-level permissions — resource must be "*".
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_top_drivers_ce" {
  name = "cost-top-drivers-ce"
  role = aws_iam_role.lambda_top_drivers_role.id

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
# RESOURCE: aws_lambda_function.lambda_top_drivers
# --------------------------------------------------------------------------------
# Description:
#   Deploys the top-drivers Lambda. Returns the top 10 AWS services by MTD
#   spend, with each service's dollar amount and percentage of total.
#
# Handler:
#   costs.top_drivers_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_top_drivers" {
  function_name    = "cost-top-drivers"
  role             = aws_iam_role.lambda_top_drivers_role.arn
  runtime          = "python3.14"
  handler          = "costs.top_drivers_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
