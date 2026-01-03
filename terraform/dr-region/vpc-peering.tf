# =============================================================================
# VPC Peering - us-east-1 <-> us-west-2
# =============================================================================
# Cross-region VPC peering for streaming replication between primary and DR

# -----------------------------------------------------------------------------
# VPC Peering Connection (Requester: DR, Accepter: Primary)
# -----------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "dr_to_primary" {
  vpc_id      = aws_vpc.dr.id
  peer_vpc_id = data.aws_vpc.primary.id
  peer_region = "us-east-1"
  auto_accept = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-peering-to-primary"
    Side = "Requester"
  })
}

# Accept the peering connection in the primary region
resource "aws_vpc_peering_connection_accepter" "primary_accepts_dr" {
  provider                  = aws.primary
  vpc_peering_connection_id = aws_vpc_peering_connection.dr_to_primary.id
  auto_accept               = true

  tags = {
    Name        = "${var.name_prefix}-peering-from-dr"
    Side        = "Accepter"
    Project     = "postgresql-ha-dr"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Route Tables - DR Region (to Primary)
# -----------------------------------------------------------------------------

# Route from DR VPC to Primary VPC via peering
resource "aws_route" "dr_to_primary" {
  route_table_id            = aws_route_table.dr_public.id
  destination_cidr_block    = "10.0.0.0/16" # Primary VPC CIDR
  vpc_peering_connection_id = aws_vpc_peering_connection.dr_to_primary.id

  depends_on = [aws_vpc_peering_connection_accepter.primary_accepts_dr]
}

# -----------------------------------------------------------------------------
# Route Tables - Primary Region (to DR)
# -----------------------------------------------------------------------------

# Get the primary VPC's main route table
data "aws_route_tables" "primary" {
  provider = aws.primary
  vpc_id   = data.aws_vpc.primary.id

  filter {
    name   = "association.main"
    values = ["false"]
  }
}

# Get public route table in primary region
data "aws_route_table" "primary_public" {
  provider = aws.primary
  vpc_id   = data.aws_vpc.primary.id

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-public-rt"]
  }
}

# Route from Primary VPC to DR VPC via peering
resource "aws_route" "primary_to_dr" {
  provider                  = aws.primary
  route_table_id            = data.aws_route_table.primary_public.id
  destination_cidr_block    = var.dr_vpc_cidr # 10.1.0.0/16
  vpc_peering_connection_id = aws_vpc_peering_connection.dr_to_primary.id

  depends_on = [aws_vpc_peering_connection_accepter.primary_accepts_dr]
}

# -----------------------------------------------------------------------------
# Security Group Updates - Primary Region (allow DR access)
# -----------------------------------------------------------------------------

# Allow PostgreSQL from DR VPC to primary Patroni nodes
resource "aws_vpc_security_group_ingress_rule" "patroni_from_dr" {
  provider          = aws.primary
  security_group_id = data.aws_security_group.primary_patroni.id
  description       = "PostgreSQL replication from DR region"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = var.dr_vpc_cidr
}

# Reference primary Patroni security group
data "aws_security_group" "primary_patroni" {
  provider = aws.primary

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-patroni-sg"]
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vpc_peering_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.dr_to_primary.id
}

output "vpc_peering_status" {
  description = "VPC Peering Connection Status"
  value       = aws_vpc_peering_connection_accepter.primary_accepts_dr.accept_status
}
