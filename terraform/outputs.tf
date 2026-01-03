# =============================================================================
# Terraform Outputs
# =============================================================================
# Outputs useful values after terraform apply.
# These can be used for documentation, scripts, or other automation.
# =============================================================================

# -----------------------------------------------------------------------------
# Backend Resources
# -----------------------------------------------------------------------------

output "state_bucket_name" {
  description = "Name of the S3 bucket storing Terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket storing Terraform state"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_locks.id
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_locks.arn
}

# -----------------------------------------------------------------------------
# Backend Configuration Snippet
# -----------------------------------------------------------------------------
# After initial apply, use this output to configure the backend.
# Copy and uncomment in backend.tf, then run `terraform init -migrate-state`
# -----------------------------------------------------------------------------

output "backend_config" {
  description = "Backend configuration to add to backend.tf after initial apply"
  value       = <<-EOT
    # Uncomment in backend.tf and run: terraform init -migrate-state
    # Replace <YOUR_AWS_PROFILE> with your AWS CLI profile name
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.terraform_state.id}"
        key            = "${var.environment}/terraform.tfstate"
        region         = "${var.aws_region}"
        encrypt        = true
        dynamodb_table = "${aws_dynamodb_table.terraform_locks.id}"
        profile        = "<YOUR_AWS_PROFILE>"
      }
    }
  EOT
}

# -----------------------------------------------------------------------------
# Networking Outputs
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_a_id" {
  description = "ID of the public subnet in AZ-a"
  value       = aws_subnet.public_a.id
}

output "public_subnet_b_id" {
  description = "ID of the public subnet in AZ-b"
  value       = aws_subnet.public_b.id
}

output "public_subnet_a_cidr" {
  description = "CIDR block of the public subnet in AZ-a"
  value       = aws_subnet.public_a.cidr_block
}

output "public_subnet_b_cidr" {
  description = "CIDR block of the public subnet in AZ-b"
  value       = aws_subnet.public_b.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

# -----------------------------------------------------------------------------
# Security Group Outputs
# -----------------------------------------------------------------------------

output "patroni_security_group_id" {
  description = "ID of the Patroni/PostgreSQL security group"
  value       = aws_security_group.patroni.id
}

output "etcd_security_group_id" {
  description = "ID of the etcd security group"
  value       = aws_security_group.etcd.id
}

# -----------------------------------------------------------------------------
# SSM Parameter Outputs (ARNs only - not values)
# -----------------------------------------------------------------------------

output "ssm_postgres_password_arn" {
  description = "ARN of the PostgreSQL password SSM parameter"
  value       = aws_ssm_parameter.postgres_password.arn
}

output "ssm_replication_password_arn" {
  description = "ARN of the replication password SSM parameter"
  value       = aws_ssm_parameter.replication_password.arn
}

output "ssm_pgbouncer_password_arn" {
  description = "ARN of the PgBouncer password SSM parameter"
  value       = aws_ssm_parameter.pgbouncer_password.arn
}

output "ssm_patroni_api_password_arn" {
  description = "ARN of the Patroni API password SSM parameter"
  value       = aws_ssm_parameter.patroni_api_password.arn
}

# -----------------------------------------------------------------------------
# IAM Outputs
# -----------------------------------------------------------------------------

output "ec2_instance_role_arn" {
  description = "ARN of the EC2 instance IAM role"
  value       = aws_iam_role.ec2_instance.arn
}

output "ec2_instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = aws_iam_instance_profile.ec2_instance.name
}

# -----------------------------------------------------------------------------
# AMI Outputs
# -----------------------------------------------------------------------------

output "ami_id" {
  description = "ID of the Amazon Linux 2023 AMI used"
  value       = data.aws_ami.amazon_linux_2023.id
}

output "ami_name" {
  description = "Name of the Amazon Linux 2023 AMI used"
  value       = data.aws_ami.amazon_linux_2023.name
}

# -----------------------------------------------------------------------------
# etcd Instance Outputs
# -----------------------------------------------------------------------------

output "etcd_instance_ids" {
  description = "IDs of the etcd EC2 instances"
  value       = { for k, v in aws_instance.etcd : k => v.id }
}

output "etcd_private_ips" {
  description = "Private IP addresses of the etcd EC2 instances"
  value       = { for k, v in aws_instance.etcd : k => v.private_ip }
}

# etcd_public_ips removed - access via bastion or SSM Session Manager

output "etcd_hosts" {
  description = "etcd hosts connection string for Patroni configuration"
  value       = join(",", [for k, v in aws_instance.etcd : "${v.private_ip}:2379"])
}

# -----------------------------------------------------------------------------
# Patroni Instance Outputs
# -----------------------------------------------------------------------------

output "patroni_instance_ids" {
  description = "IDs of the Patroni EC2 instances"
  value       = { for k, v in aws_instance.patroni : k => v.id }
}

output "patroni_private_ips" {
  description = "Private IP addresses of the Patroni EC2 instances"
  value       = { for k, v in aws_instance.patroni : k => v.private_ip }
}

# patroni_public_ips removed - access via NLB, bastion, or SSM Session Manager

# -----------------------------------------------------------------------------
# Connection Information
# -----------------------------------------------------------------------------

output "ssh_via_bastion" {
  description = "SSH commands to connect to instances via bastion"
  value = {
    bastion = "ssh -i <key.pem> ec2-user@${aws_eip.bastion.public_ip}"
    etcd = {
      for k, v in aws_instance.etcd : k => "ssh -J ec2-user@${aws_eip.bastion.public_ip} ec2-user@${v.private_ip}"
    }
    patroni = {
      for k, v in aws_instance.patroni : k => "ssh -J ec2-user@${aws_eip.bastion.public_ip} ec2-user@${v.private_ip}"
    }
  }
}

output "patroni_api_urls" {
  description = "Patroni REST API URLs (accessible via SSH tunnel)"
  value       = { for k, v in aws_instance.patroni : k => "http://${v.private_ip}:8008" }
}

# -----------------------------------------------------------------------------
# Network Load Balancer Outputs
# -----------------------------------------------------------------------------

output "nlb_dns_name" {
  description = "DNS name of the Network Load Balancer"
  value       = aws_lb.postgres.dns_name
}

output "nlb_arn" {
  description = "ARN of the Network Load Balancer"
  value       = aws_lb.postgres.arn
}

output "nlb_zone_id" {
  description = "Zone ID of the Network Load Balancer (for Route 53 alias records)"
  value       = aws_lb.postgres.zone_id
}

output "primary_target_group_arn" {
  description = "ARN of the primary (R/W) target group"
  value       = aws_lb_target_group.primary.arn
}

output "replicas_target_group_arn" {
  description = "ARN of the replicas (RO) target group"
  value       = aws_lb_target_group.replicas.arn
}

output "pgbouncer_target_group_arn" {
  description = "ARN of the PgBouncer (connection pooling) target group"
  value       = aws_lb_target_group.pgbouncer.arn
}

# -----------------------------------------------------------------------------
# PostgreSQL Connection Strings via NLB
# -----------------------------------------------------------------------------

output "connection_string_rw" {
  description = "psql command for read-write connections (connects to primary)"
  value       = "psql -h ${aws_lb.postgres.dns_name} -p 5432 -U postgres -d postgres"
}

output "connection_string_ro" {
  description = "psql command for read-only connections (connects to replicas)"
  value       = "psql -h ${aws_lb.postgres.dns_name} -p 5433 -U postgres -d postgres"
}

output "jdbc_url_rw" {
  description = "JDBC URL for read-write connections"
  value       = "jdbc:postgresql://${aws_lb.postgres.dns_name}:5432/postgres"
}

output "jdbc_url_ro" {
  description = "JDBC URL for read-only connections"
  value       = "jdbc:postgresql://${aws_lb.postgres.dns_name}:5433/postgres"
}

output "connection_string_pgbouncer" {
  description = "psql command for pooled connections (via PgBouncer - recommended for apps)"
  value       = "psql -h ${aws_lb.postgres.dns_name} -p 6432 -U postgres -d postgres"
}

output "jdbc_url_pgbouncer" {
  description = "JDBC URL for pooled connections (via PgBouncer - recommended for apps)"
  value       = "jdbc:postgresql://${aws_lb.postgres.dns_name}:6432/postgres"
}

# -----------------------------------------------------------------------------
# Bastion Host Outputs
# -----------------------------------------------------------------------------

output "bastion_instance_id" {
  description = "ID of the bastion host EC2 instance"
  value       = aws_instance.bastion.id
}

output "bastion_public_ip" {
  description = "Public IP address of the bastion host (Elastic IP - static)"
  value       = aws_eip.bastion.public_ip
}

output "bastion_eip_id" {
  description = "Allocation ID of the bastion Elastic IP"
  value       = aws_eip.bastion.id
}

output "bastion_private_ip" {
  description = "Private IP address of the bastion host"
  value       = aws_instance.bastion.private_ip
}

output "bastion_ssh_command" {
  description = "SSH command to connect to the bastion host"
  value       = "ssh -i <key.pem> ec2-user@${aws_eip.bastion.public_ip}"
}
