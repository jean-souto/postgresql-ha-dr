# =============================================================================
# IAM Resources
# =============================================================================
# Creates IAM roles and policies for EC2 instances to access AWS services.
# Follows least-privilege principle with specific permissions.
# =============================================================================

# -----------------------------------------------------------------------------
# IAM Role for EC2 Instances
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ec2_instance" {
  name        = "${local.name_prefix}-ec2-role"
  description = "IAM role for PostgreSQL HA EC2 instances"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-role"
  })
}

# -----------------------------------------------------------------------------
# IAM Instance Profile
# -----------------------------------------------------------------------------

resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_instance.name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-profile"
  })
}

# -----------------------------------------------------------------------------
# IAM Policy: SSM Parameter Store Access
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "ssm_parameters" {
  name = "${local.name_prefix}-ssm-access"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/pgha/*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Policy: CloudWatch Logs
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${local.name_prefix}-cloudwatch-logs"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/pgha/*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Policy: EC2 Describe (for cluster discovery)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "ec2_describe" {
  name = "${local.name_prefix}-ec2-describe"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Policy: SSM Session Manager (for remote access)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
