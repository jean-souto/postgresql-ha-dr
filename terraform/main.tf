# =============================================================================
# Terraform State Backend Resources (S3 + DynamoDB)
# =============================================================================
# Creates infrastructure for remote state management (S3 + DynamoDB locking).
#
# LAB/DEMO MODE (current):
#   - Backend is NOT enabled (see backend.tf - commented out)
#   - State is stored locally in terraform.tfstate
#   - These resources are created but not used
#   - `terraform destroy` removes everything cleanly
#
# PRODUCTION MODE:
#   1. Add `lifecycle { prevent_destroy = true }` to the S3 bucket below
#   2. Remove `force_destroy = true` from the S3 bucket
#   3. Uncomment the backend configuration in backend.tf
#   4. Run `terraform init -migrate-state` to migrate to S3
#   5. Now state is protected and shared across team members
#
# =============================================================================

# -----------------------------------------------------------------------------
# S3 Bucket for Terraform State
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = local.state_bucket_name

  # Lab project: allow destroy with infrastructure
  force_destroy = true

  tags = {
    Name        = local.state_bucket_name
    Description = "Terraform state storage for PostgreSQL HA project"
  }
}

# Enable versioning for state recovery
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption (SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block all public access to state bucket
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# DynamoDB Table for State Locking
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name         = local.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = local.dynamodb_table_name
    Description = "Terraform state locking for PostgreSQL HA project"
  }
}
