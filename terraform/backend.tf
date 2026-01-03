# =============================================================================
# Terraform Backend Configuration (S3 + DynamoDB)
# =============================================================================
# CURRENTLY DISABLED - Using local state for lab/demo simplicity.
#
# The S3 bucket and DynamoDB table ARE created (see main.tf) but not used.
# This allows clean `terraform destroy` without state management issues.
#
# TO ENABLE FOR PRODUCTION:
# 1. Update main.tf: add prevent_destroy, remove force_destroy
# 2. Uncomment the backend block below (update values)
# 3. Run: terraform init -migrate-state
#
# TO DESTROY WITH S3 BACKEND ENABLED:
# 1. Comment out the backend block below
# 2. Run: terraform init -migrate-state (back to local)
# 3. Run: terraform destroy
# =============================================================================

# terraform {
#   backend "s3" {
#     bucket         = "pgha-terraform-state-YOUR_ACCOUNT_ID"
#     key            = "dev/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "pgha-terraform-locks"
#     profile        = "postgresql-ha-profile"
#   }
# }
