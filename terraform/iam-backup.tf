# =============================================================================
# IAM Policies for pgBackRest S3 Access
# =============================================================================
# This file extends the EC2 instance role with permissions to:
# - Read/write to the pgBackRest S3 bucket
# - List bucket contents
# - Delete old backup files (for retention management)
#
# Security considerations:
# - Least privilege: only necessary actions allowed
# - Resource-scoped: only the specific bucket is accessible
# - No wildcard resources
# =============================================================================

# -----------------------------------------------------------------------------
# pgBackRest S3 Access Policy
# -----------------------------------------------------------------------------
# Attach to EC2 instance role to allow pgBackRest to access S3
resource "aws_iam_role_policy" "pgbackrest_s3" {
  name = "${local.name_prefix}-pgbackrest-s3"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.pgbackrest.arn
      },
      {
        Sid    = "ReadWriteObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion"
        ]
        Resource = "${aws_s3_bucket.pgbackrest.arn}/*"
      },
      {
        Sid    = "MultipartUpload"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.pgbackrest.arn}/*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Logs for pgBackRest (Optional but recommended)
# -----------------------------------------------------------------------------
# Allow EC2 instances to send pgBackRest logs to CloudWatch
resource "aws_iam_role_policy" "pgbackrest_logs" {
  name = "${local.name_prefix}-pgbackrest-logs"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/pgbackrest/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/pgbackrest/*:log-stream:*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for pgBackRest
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "pgbackrest" {
  name              = "/pgbackrest/${local.name_prefix}"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-pgbackrest-logs"
    Component = "disaster-recovery"
  })
}
