# =============================================================================
# AWS Provider Configuration
# =============================================================================
# Configures the AWS provider with region and authentication settings.
# Update the profile below to match your AWS CLI profile name.
# =============================================================================

provider "aws" {
  region  = var.aws_region
  profile = "postgresql-ha-profile"

  default_tags {
    tags = local.common_tags
  }
}
