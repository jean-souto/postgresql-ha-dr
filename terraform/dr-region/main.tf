# =============================================================================
# PostgreSQL HA/DR - Disaster Recovery Region (us-west-2)
# =============================================================================
# This module creates the DR infrastructure in us-west-2

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------

provider "aws" {
  region  = "us-west-2"
  profile = "postgresql-ha-profile"

  default_tags {
    tags = {
      Project     = "postgresql-ha-dr"
      Environment = var.environment
      ManagedBy   = "terraform"
      Region      = "us-west-2"
      Role        = "disaster-recovery"
    }
  }
}

# Provider for primary region (to reference resources)
provider "aws" {
  alias   = "primary"
  region  = "us-east-1"
  profile = "postgresql-ha-profile"
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Reference primary region VPC (for peering)
data "aws_vpc" "primary" {
  provider = aws.primary

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-vpc"]
  }
}

# Reference primary S3 bucket
data "aws_s3_bucket" "primary_pgbackrest" {
  provider = aws.primary
  bucket   = "${var.name_prefix}-pgbackrest-${data.aws_caller_identity.current.account_id}"
}

# Reference primary NLB for streaming replication endpoint
data "aws_lb" "primary_nlb" {
  provider = aws.primary
  name     = "${var.name_prefix}-nlb"
}

# Get primary Patroni instance IPs (for pg_basebackup)
data "aws_instances" "primary_patroni" {
  provider = aws.primary

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-patroni-*"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# -----------------------------------------------------------------------------
# Local Values
# -----------------------------------------------------------------------------

locals {
  name_prefix = "${var.name_prefix}-dr"

  common_tags = {
    Project     = "postgresql-ha-dr"
    Environment = var.environment
    Region      = "us-west-2"
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "pgha-dev"
}

variable "dr_vpc_cidr" {
  description = "CIDR block for DR VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "acesso staging-veta"
}
