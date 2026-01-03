# =============================================================================
# EC2 Instances: etcd Cluster
# =============================================================================
# Creates EC2 instances for the etcd distributed key-value store.
# etcd provides the consensus layer for Patroni leader election.
# Instance type and count are configurable via variables.
# =============================================================================

# -----------------------------------------------------------------------------
# Local values for etcd configuration
# -----------------------------------------------------------------------------

locals {
  # etcd instance configurations with fixed private IPs
  # Host offsets 266-268 place instances in the public subnet (x.x.1.10-12 with default CIDR)
  etcd_instances = {
    0 = { name = "${local.name_prefix}-etcd-1", private_ip = cidrhost(var.vpc_cidr, 266) }
    1 = { name = "${local.name_prefix}-etcd-2", private_ip = cidrhost(var.vpc_cidr, 267) }
    2 = { name = "${local.name_prefix}-etcd-3", private_ip = cidrhost(var.vpc_cidr, 268) }
  }

  # etcd cluster token for initial cluster formation
  etcd_cluster_token = "${local.name_prefix}-etcd-cluster"
}

# -----------------------------------------------------------------------------
# EC2 Instances for etcd
# -----------------------------------------------------------------------------

resource "aws_instance" "etcd" {
  for_each = local.etcd_instances

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = local.effective_key_name
  subnet_id              = aws_subnet.public_a.id
  private_ip             = each.value.private_ip # Fixed IP for cluster formation
  vpc_security_group_ids = [aws_security_group.etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance.name

  # 8GB gp2 root volume for etcd
  root_block_device {
    volume_size           = var.etcd_root_volume_size
    volume_type           = "gp2"
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, {
      Name = "${each.value.name}-root"
    })
  }

  # User data script for etcd bootstrap
  user_data = templatefile("${path.module}/scripts/user-data-etcd.sh.tpl", {
    instance_name = each.value.name
    etcd_version  = var.etcd_version
    cluster_token = local.etcd_cluster_token
    # Initial cluster uses fixed private IPs defined in local.etcd_instances
    initial_cluster = join(",", [
      for idx, inst in local.etcd_instances :
      "${inst.name}=http://${inst.private_ip}:2380"
    ])
  })

  # Ensure instances wait for security group to be fully created
  depends_on = [
    aws_security_group.etcd,
    aws_iam_instance_profile.ec2_instance
  ]

  tags = merge(local.common_tags, {
    Name = each.value.name
    Role = "etcd"
  })

  lifecycle {
    # Prevent accidental destruction
    prevent_destroy = false

    # Ignore changes to user_data after creation (requires instance replacement)
    ignore_changes = [user_data]
  }
}

# -----------------------------------------------------------------------------
# Elastic IPs for etcd instances - REMOVED
# -----------------------------------------------------------------------------
# EIPs removed to improve security. Access etcd via:
# 1. SSH through bastion host
# 2. SSM Session Manager
# -----------------------------------------------------------------------------
