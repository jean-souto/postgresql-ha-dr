# =============================================================================
# EC2 API Server - Docker-based API Deployment
# =============================================================================
# Deploys the PostgreSQL HA/DR Demo APIs on EC2 with Docker Compose
# This is a Free Tier compatible alternative to App Runner
#
# Architecture:
# - Single t3.micro instance running both APIs
# - Docker Compose for container orchestration
# - Images pulled from ECR
# - Direct VPC access to PostgreSQL cluster
# =============================================================================

# -----------------------------------------------------------------------------
# Security Group for API Server
# -----------------------------------------------------------------------------

resource "aws_security_group" "api_server" {
  name        = "${local.name_prefix}-api-server-sg"
  description = "Security group for API server"
  vpc_id      = aws_vpc.main.id

  # SSH access (via bastion or direct if needed)
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Python API (FastAPI)
  ingress {
    description = "FastAPI from anywhere"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Go API (Gin)
  ingress {
    description = "Go API from anywhere"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-api-server-sg"
  })
}

# Allow API server to connect to PostgreSQL
resource "aws_security_group_rule" "postgres_from_api_server" {
  type                     = "ingress"
  description              = "PostgreSQL from API server"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.api_server.id
  security_group_id        = aws_security_group.patroni.id
}

resource "aws_security_group_rule" "pgbouncer_from_api_server" {
  type                     = "ingress"
  description              = "PgBouncer from API server"
  from_port                = 6432
  to_port                  = 6432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.api_server.id
  security_group_id        = aws_security_group.patroni.id
}

# -----------------------------------------------------------------------------
# IAM Role for API Server (ECR access + SSM)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "api_server" {
  name = "${local.name_prefix}-api-server-role"

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

resource "aws_iam_instance_profile" "api_server" {
  name = "${local.name_prefix}-api-server-profile"
  role = aws_iam_role.api_server.name
}

# ECR access policy
resource "aws_iam_role_policy" "api_server_ecr" {
  name = "${local.name_prefix}-api-server-ecr"
  role = aws_iam_role.api_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = [
          aws_ecr_repository.api_python.arn,
          aws_ecr_repository.api_go.arn
        ]
      }
    ]
  })
}

# SSM access for secrets
resource "aws_iam_role_policy" "api_server_ssm" {
  name = "${local.name_prefix}-api-server-ssm"
  role = aws_iam_role.api_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          aws_ssm_parameter.postgres_password.arn,
          aws_ssm_parameter.pgbouncer_password.arn
        ]
      }
    ]
  })
}

# SSM Managed Instance Core for Session Manager
resource "aws_iam_role_policy_attachment" "api_server_ssm_managed" {
  role       = aws_iam_role.api_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# EC2 Instance - API Server
# -----------------------------------------------------------------------------

resource "aws_instance" "api_server" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = local.effective_key_name
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.api_server.id]
  iam_instance_profile   = aws_iam_instance_profile.api_server.name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/user-data-api.sh.tpl", {
    aws_region          = var.aws_region
    ecr_python_repo     = aws_ecr_repository.api_python.repository_url
    ecr_go_repo         = aws_ecr_repository.api_go.repository_url
    db_host             = aws_lb.postgres.dns_name
    db_port             = "5432"
    db_name             = "postgres"
    db_user             = "postgres"
    ssm_password_param  = aws_ssm_parameter.postgres_password.name
    pgbackrest_stanza   = local.patroni_cluster_name
  })

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-api-server"
    Component = "api"
  })

  depends_on = [
    aws_lb.postgres,
    aws_ecr_repository.api_python,
    aws_ecr_repository.api_go
  ]
}

# Elastic IP for API Server (stable public IP)
resource "aws_eip" "api_server" {
  instance = aws_instance.api_server.id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-api-server-eip"
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "api_server_public_ip" {
  description = "Public IP of the API server"
  value       = aws_eip.api_server.public_ip
}

output "api_server_private_ip" {
  description = "Private IP of the API server"
  value       = aws_instance.api_server.private_ip
}

output "api_python_url" {
  description = "URL for Python FastAPI"
  value       = "http://${aws_eip.api_server.public_ip}:8000"
}

output "api_go_url" {
  description = "URL for Go Gin API"
  value       = "http://${aws_eip.api_server.public_ip}:8001"
}

output "api_server_ssh" {
  description = "SSH command to connect to API server via bastion"
  value       = "ssh -J ec2-user@${aws_eip.bastion.public_ip} ec2-user@${aws_instance.api_server.private_ip}"
}
