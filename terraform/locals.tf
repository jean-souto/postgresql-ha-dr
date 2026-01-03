# =============================================================================
# Local Values
# =============================================================================
# Defines computed values and common configurations used across resources.
# Includes naming conventions and common tags.
# =============================================================================

locals {
  # Resource naming prefix: pgha-dev-*
  name_prefix = "${var.project_name}-${var.environment}"

  # Common tags applied to all resources
  # Note: These are also applied via provider default_tags
  common_tags = {
    Project     = "postgresql-ha-dr"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "dbre-team"
  }

  # S3 backend configuration values
  state_bucket_name   = "${var.project_name}-terraform-state-${var.aws_account_id}"
  dynamodb_table_name = "${var.project_name}-terraform-locks"
}
