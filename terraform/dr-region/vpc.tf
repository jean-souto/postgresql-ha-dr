# =============================================================================
# VPC Configuration - DR Region (us-west-2)
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "dr" {
  cidr_block           = var.dr_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "dr" {
  vpc_id = aws_vpc.dr.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------

resource "aws_subnet" "dr_public_a" {
  vpc_id                  = aws_vpc.dr.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 8, 1)
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-a"
    Type = "public"
  })
}

resource "aws_subnet" "dr_public_b" {
  vpc_id                  = aws_vpc.dr.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 8, 2)
  availability_zone       = "us-west-2b"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-b"
    Type = "public"
  })
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------

resource "aws_route_table" "dr_public" {
  vpc_id = aws_vpc.dr.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "dr_public_a" {
  subnet_id      = aws_subnet.dr_public_a.id
  route_table_id = aws_route_table.dr_public.id
}

resource "aws_route_table_association" "dr_public_b" {
  subnet_id      = aws_subnet.dr_public_b.id
  route_table_id = aws_route_table.dr_public.id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "dr_postgres" {
  name        = "${local.name_prefix}-postgres-sg"
  description = "Security group for DR PostgreSQL instance"
  vpc_id      = aws_vpc.dr.id

  # PostgreSQL
  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.dr_vpc_cidr, "10.0.0.0/16"] # DR VPC + Primary VPC
  }

  # PgBouncer
  ingress {
    description = "PgBouncer"
    from_port   = 6432
    to_port     = 6432
    protocol    = "tcp"
    cidr_blocks = [var.dr_vpc_cidr]
  }

  # Patroni API
  ingress {
    description = "Patroni REST API"
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    cidr_blocks = [var.dr_vpc_cidr]
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
    Name = "${local.name_prefix}-postgres-sg"
  })
}
