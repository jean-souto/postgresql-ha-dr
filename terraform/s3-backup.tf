# =============================================================================
# S3 Bucket for pgBackRest - WAL Archive and Backups
# =============================================================================
# This bucket stores:
# - WAL archive files (continuous archiving for PITR)
# - Full backups (weekly)
# - Differential backups (daily)
#
# Retention Policy:
# - 2 full backups retained
# - 7 differential backups retained
# - WAL files: as needed for PITR within retention window
#
# Lifecycle:
# - STANDARD: 0-30 days (active backups)
# - STANDARD_IA: 30-90 days (infrequent access)
# - GLACIER: 90-365 days (archive)
# - Delete: after 365 days
# =============================================================================

# -----------------------------------------------------------------------------
# S3 Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "pgbackrest" {
  bucket = "${local.name_prefix}-pgbackrest-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental deletion of backup data
  # Set to true in production, false for dev/testing
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name       = "${local.name_prefix}-pgbackrest"
    Purpose    = "PostgreSQL WAL Archive and Backups"
    Component  = "disaster-recovery"
    BackupType = "pgbackrest"
    Encryption = "AES256"
  })
}

# -----------------------------------------------------------------------------
# Bucket Versioning
# -----------------------------------------------------------------------------
# Enabled to protect against accidental deletion and corruption
resource "aws_s3_bucket_versioning" "pgbackrest" {
  bucket = aws_s3_bucket.pgbackrest.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Lifecycle Configuration
# -----------------------------------------------------------------------------
# Optimize storage costs by transitioning old backups to cheaper storage classes
resource "aws_s3_bucket_lifecycle_configuration" "pgbackrest" {
  bucket = aws_s3_bucket.pgbackrest.id

  # Rule for backup files
  rule {
    id     = "archive-old-backups"
    status = "Enabled"

    filter {
      prefix = "pgbackrest/"
    }

    # Move to Infrequent Access after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Move to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Delete after 365 days
    expiration {
      days = 365
    }

    # Clean up incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Clean up old versions
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # Rule for WAL archive files (keep longer for PITR capability)
  rule {
    id     = "archive-wal-files"
    status = "Enabled"

    filter {
      prefix = "pgbackrest/archive/"
    }

    # WAL files to IA after 30 days (minimum for STANDARD_IA)
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # WAL files to Glacier after 60 days
    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    # Delete WAL files after 180 days
    expiration {
      days = 180
    }
  }
}

# -----------------------------------------------------------------------------
# Server-Side Encryption
# -----------------------------------------------------------------------------
# Use AES256 (S3-managed keys) for cost-effective encryption
# For higher security requirements, use aws:kms with CMK
resource "aws_s3_bucket_server_side_encryption_configuration" "pgbackrest" {
  bucket = aws_s3_bucket.pgbackrest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# -----------------------------------------------------------------------------
# Block Public Access
# -----------------------------------------------------------------------------
# Ensure bucket is completely private - backup data should never be public
resource "aws_s3_bucket_public_access_block" "pgbackrest" {
  bucket = aws_s3_bucket.pgbackrest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Bucket Policy
# -----------------------------------------------------------------------------
# Restrict access to only the EC2 instances with the correct IAM role
resource "aws_s3_bucket_policy" "pgbackrest" {
  bucket = aws_s3_bucket.pgbackrest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2InstanceAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ec2_instance.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.pgbackrest.arn,
          "${aws_s3_bucket.pgbackrest.arn}/*"
        ]
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.pgbackrest.arn,
          "${aws_s3_bucket.pgbackrest.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.pgbackrest]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "pgbackrest_bucket_name" {
  description = "Name of the S3 bucket for pgBackRest"
  value       = aws_s3_bucket.pgbackrest.id
}

output "pgbackrest_bucket_arn" {
  description = "ARN of the S3 bucket for pgBackRest"
  value       = aws_s3_bucket.pgbackrest.arn
}

output "pgbackrest_bucket_region" {
  description = "Region of the S3 bucket"
  value       = aws_s3_bucket.pgbackrest.region
}

output "pgbackrest_bucket_domain" {
  description = "Domain name of the S3 bucket"
  value       = aws_s3_bucket.pgbackrest.bucket_domain_name
}
