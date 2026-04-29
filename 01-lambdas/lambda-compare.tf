# ================================================================================
# File: lambda-compare.tf
# ================================================================================
# Purpose:
#   Deploys the "Compare Months" Lambda function that compares this month's
#   MTD spend against last month's total spend.
#   Invoked via POST /cost/compare-months.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_compare_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_compare_role" {
  name = "cost-compare-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_compare_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_compare_basic" {
  role       = aws_iam_role.lambda_compare_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_compare_ce
# --------------------------------------------------------------------------------
# Description:
#   Inline policy granting read-only Cost Explorer access.
#   CE does not support resource-level permissions — resource must be "*".
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_compare_ce" {
  name = "cost-compare-ce"
  role = aws_iam_role.lambda_compare_role.id

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
# RESOURCE: aws_lambda_function.lambda_compare
# --------------------------------------------------------------------------------
# Description:
#   Deploys the compare-months Lambda. Makes two CE calls — this month MTD
#   and last month full — then returns a plain-text delta summary.
#
# Handler:
#   costs.compare_handler  (code/costs.py)
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_compare" {
  function_name    = "cost-compare"
  role             = aws_iam_role.lambda_compare_role.arn
  runtime          = "python3.14"
  handler          = "costs.compare_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15
}
