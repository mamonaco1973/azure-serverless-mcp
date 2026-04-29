#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the Cost Explorer MCP API stack deployed by apply.sh.
#   Destroys all Lambda functions, API Gateway, and IAM roles.
# ================================================================================

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------

# Default AWS region used by AWS CLI and Terraform providers.
export AWS_DEFAULT_REGION="us-east-1"

# Enable strict shell execution:
#   -e  Exit immediately on command failure
#   -u  Treat unset variables as errors
#   -o pipefail  Propagate failures across piped commands
set -euo pipefail

# ------------------------------------------------------------------------------
# Destroy Lambda functions and API Gateway
# ------------------------------------------------------------------------------

# Removes all infrastructure including:
#   - Six cost-query Lambda functions
#   - API Gateway (HTTP API) and routes/integrations
#   - IAM roles and inline Cost Explorer policies
# provisioned by Terraform in the 01-lambdas directory.
echo "NOTE: Destroying Lambdas and API Gateway..."

cd 01-lambdas || {
  echo "ERROR: Directory 01-lambdas not found."
  exit 1
}

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------

# Indicates that all Terraform stacks completed teardown successfully.
echo "NOTE: Infrastructure teardown complete."

# ================================================================================
# End of script
# ================================================================================
