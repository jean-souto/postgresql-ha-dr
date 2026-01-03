# =============================================================================
# DR Standby PostgreSQL Instance
# =============================================================================
# Single standby instance that can be activated in case of primary region failure

# -----------------------------------------------------------------------------
# IAM Role for DR Instance
# -----------------------------------------------------------------------------

resource "aws_iam_role" "dr_instance" {
  name = "${local.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_instance_profile" "dr_instance" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.dr_instance.name
}

# SSM access for parameters
resource "aws_iam_role_policy" "dr_ssm" {
  name = "${local.name_prefix}-ssm-policy"
  role = aws_iam_role.dr_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/pgha/*"
      }
    ]
  })
}

# SSM Managed Instance Core for Session Manager
resource "aws_iam_role_policy_attachment" "dr_ssm_managed" {
  role       = aws_iam_role.dr_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 access for pgBackRest (both regions)
resource "aws_iam_role_policy" "dr_pgbackrest" {
  name = "${local.name_prefix}-pgbackrest-policy"
  role = aws_iam_role.dr_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          data.aws_s3_bucket.primary_pgbackrest.arn,
          aws_s3_bucket.dr_pgbackrest.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${data.aws_s3_bucket.primary_pgbackrest.arn}/*",
          "${aws_s3_bucket.dr_pgbackrest.arn}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 Bucket for DR Region (replica or independent)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "dr_pgbackrest" {
  bucket        = "${local.name_prefix}-pgbackrest-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment == "dev" ? true : false

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-pgbackrest"
    Purpose = "DR PostgreSQL Backups"
  })
}

resource "aws_s3_bucket_versioning" "dr_pgbackrest" {
  bucket = aws_s3_bucket.dr_pgbackrest.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dr_pgbackrest" {
  bucket = aws_s3_bucket.dr_pgbackrest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dr_pgbackrest" {
  bucket = aws_s3_bucket.dr_pgbackrest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# DR Standby Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "dr_standby" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.dr_public_a.id
  vpc_security_group_ids = [aws_security_group.dr_postgres.id]
  iam_instance_profile   = aws_iam_instance_profile.dr_instance.name
  # key_name omitted - use SSM Session Manager for access

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/user-data-standby.sh.tpl", {
    instance_name     = "${local.name_prefix}-standby-1"
    cluster_name      = "${var.name_prefix}-postgres"
    aws_region        = "us-west-2"
    primary_region    = "us-east-1"
    pgbackrest_bucket = aws_s3_bucket.dr_pgbackrest.id
    primary_bucket    = data.aws_s3_bucket.primary_pgbackrest.id
    pgbackrest_stanza = "${var.name_prefix}-postgres"
    # For streaming replication via VPC Peering
    primary_host      = data.aws_lb.primary_nlb.dns_name
    primary_ips       = join(",", data.aws_instances.primary_patroni.private_ips)
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-standby-1"
    Role = "standby"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "dr_vpc_id" {
  description = "DR VPC ID"
  value       = aws_vpc.dr.id
}

output "dr_vpc_cidr" {
  description = "DR VPC CIDR"
  value       = aws_vpc.dr.cidr_block
}

output "dr_standby_ip" {
  description = "DR Standby instance public IP"
  value       = aws_instance.dr_standby.public_ip
}

output "dr_standby_private_ip" {
  description = "DR Standby instance private IP"
  value       = aws_instance.dr_standby.private_ip
}

output "dr_s3_bucket" {
  description = "DR S3 bucket for pgBackRest"
  value       = aws_s3_bucket.dr_pgbackrest.id
}
