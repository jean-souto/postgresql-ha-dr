# =============================================================================
# EC2 Instance: Bastion Host
# =============================================================================
# Creates a bastion host for secure access to internal resources.
# This instance is NOT a target of the NLB, so it can test NLB connectivity.
# =============================================================================

# -----------------------------------------------------------------------------
# Security Group: Bastion Host
# -----------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bastion-sg"
  })
}

# SSH from admin IP
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from admin"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_ip
}

# All outbound traffic
resource "aws_vpc_security_group_egress_rule" "bastion_all_outbound" {
  security_group_id = aws_security_group.bastion.id
  description       = "All outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# EC2 Instance: Bastion Host
# -----------------------------------------------------------------------------

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.micro"
  key_name                    = local.effective_key_name
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance.name # For SSM access
  associate_public_ip_address = false                                      # EIP will provide public IP

  # Minimal root volume (AL2023 requires 30GB minimum)
  root_block_device {
    volume_size           = 30
    volume_type           = "gp2"
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-bastion-root"
    })
  }

  # Install PostgreSQL client for testing
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Set hostname
    hostnamectl set-hostname ${local.name_prefix}-bastion

    # Update system
    dnf update -y

    # Install PostgreSQL 17 client only
    dnf install -y postgresql17

    echo "Bastion host ready"
  EOF

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bastion"
    Role = "bastion"
  })

  lifecycle {
    prevent_destroy = false
  }
}

# -----------------------------------------------------------------------------
# Elastic IP: Bastion Host
# -----------------------------------------------------------------------------
# Static public IP for consistent SSH access

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bastion-eip"
  })

  depends_on = [aws_internet_gateway.main]
}
