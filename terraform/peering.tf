# =============================================================================
# VPC Peering - Cross-Region Connectivity
# =============================================================================
# Establishes VPC peering between primary (us-east-1) and DR (us-west-2)

# -----------------------------------------------------------------------------
# Provider for DR Region
# -----------------------------------------------------------------------------

provider "aws" {
  alias   = "dr"
  region  = "us-west-2"
  profile = "postgresql-ha-profile"
}

# -----------------------------------------------------------------------------
# Data Sources for DR VPC
# -----------------------------------------------------------------------------

data "aws_vpc" "dr" {
  provider = aws.dr

  filter {
    name   = "tag:Name"
    values = ["${local.name_prefix}-dr-vpc"]
  }

  # Only try to get this if DR region is deployed
  count = var.enable_dr_region ? 1 : 0
}

# -----------------------------------------------------------------------------
# VPC Peering Connection
# -----------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "primary_to_dr" {
  count = var.enable_dr_region ? 1 : 0

  vpc_id      = aws_vpc.main.id
  peer_vpc_id = data.aws_vpc.dr[0].id
  peer_region = "us-west-2"
  auto_accept = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-peering-to-dr"
    Side = "requester"
  })
}

# -----------------------------------------------------------------------------
# VPC Peering Accepter (in DR region)
# -----------------------------------------------------------------------------

resource "aws_vpc_peering_connection_accepter" "dr_accept" {
  count    = var.enable_dr_region ? 1 : 0
  provider = aws.dr

  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_dr[0].id
  auto_accept               = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-peering-from-primary"
    Side = "accepter"
  })
}

# -----------------------------------------------------------------------------
# Route Tables - Primary to DR
# -----------------------------------------------------------------------------

resource "aws_route" "primary_to_dr" {
  count = var.enable_dr_region ? 1 : 0

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = "10.1.0.0/16" # DR VPC CIDR
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_dr[0].id
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "enable_dr_region" {
  description = "Enable cross-region DR infrastructure"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vpc_peering_id" {
  description = "VPC Peering Connection ID"
  value       = var.enable_dr_region ? aws_vpc_peering_connection.primary_to_dr[0].id : null
}

output "vpc_peering_status" {
  description = "VPC Peering Connection Status"
  value       = var.enable_dr_region ? aws_vpc_peering_connection.primary_to_dr[0].accept_status : "disabled"
}
