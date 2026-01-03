# =============================================================================
# Monitoring Stack - Prometheus, Grafana, Alertmanager
# =============================================================================
# Deploys observability infrastructure for the PostgreSQL HA cluster

# -----------------------------------------------------------------------------
# Security Group for Monitoring
# -----------------------------------------------------------------------------

resource "aws_security_group" "monitoring" {
  name        = "${local.name_prefix}-monitoring-sg"
  description = "Security group for monitoring instance"
  vpc_id      = aws_vpc.main.id

  # Prometheus
  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana
  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Alertmanager
  ingress {
    description = "Alertmanager UI"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-monitoring-sg"
  })
}

# -----------------------------------------------------------------------------
# IAM Role for Monitoring Instance
# -----------------------------------------------------------------------------

resource "aws_iam_role" "monitoring" {
  name = "${local.name_prefix}-monitoring-role"

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

resource "aws_iam_instance_profile" "monitoring" {
  name = "${local.name_prefix}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

# SSM access for remote management
resource "aws_iam_role_policy_attachment" "monitoring_ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch access for metrics
resource "aws_iam_role_policy" "monitoring_cloudwatch" {
  name = "${local.name_prefix}-monitoring-cloudwatch"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      }
    ]
  })
}

# SNS access for alerts
resource "aws_iam_role_policy" "monitoring_sns" {
  name = "${local.name_prefix}-monitoring-sns"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# EC2 describe for auto-discovery
resource "aws_iam_role_policy" "monitoring_ec2" {
  name = "${local.name_prefix}-monitoring-ec2"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SNS Topic for Alerts
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = local.common_tags
}

# Email subscription (add your email)
resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# Monitoring EC2 Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name
  key_name               = local.effective_key_name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Using base64gzip to compress user_data (original script exceeds 16KB limit)
  user_data_base64 = base64gzip(templatefile("${path.module}/scripts/user-data-monitoring.sh.tpl", {
    prometheus_version   = "2.54.1"
    grafana_version      = "11.4.0"
    alertmanager_version = "0.27.0"
    postgres_targets     = join(",", [for k, v in aws_instance.patroni : "${v.private_ip}:9187"])
    node_targets         = join(",", [for k, v in aws_instance.patroni : "${v.private_ip}:9100"])
    patroni_targets      = join(",", [for k, v in aws_instance.patroni : "${v.private_ip}:8008"])
    pgbouncer_targets    = join(",", [for k, v in aws_instance.patroni : "${v.private_ip}:9127"])
    etcd_targets         = join(",", [for k, v in aws_instance.etcd : "${v.private_ip}:2379"])
    sns_topic_arn        = aws_sns_topic.alerts.arn
    aws_region           = var.aws_region
    cluster_name         = local.patroni_cluster_name
  }))

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-monitoring"
    Role = "observability"
  })

  depends_on = [aws_instance.patroni, aws_instance.etcd]

  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "enable_monitoring" {
  description = "Enable monitoring instance"
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address for alert notifications"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "monitoring_public_ip" {
  description = "Monitoring instance public IP"
  value       = var.enable_monitoring ? aws_instance.monitoring[0].public_ip : null
}

output "prometheus_url" {
  description = "Prometheus URL"
  value       = var.enable_monitoring ? "http://${aws_instance.monitoring[0].public_ip}:9090" : null
}

output "grafana_url" {
  description = "Grafana URL"
  value       = var.enable_monitoring ? "http://${aws_instance.monitoring[0].public_ip}:3000" : null
}

output "alertmanager_url" {
  description = "Alertmanager URL"
  value       = var.enable_monitoring ? "http://${aws_instance.monitoring[0].public_ip}:9093" : null
}

output "sns_topic_arn" {
  description = "SNS Topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}
