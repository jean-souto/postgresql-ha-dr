# =============================================================================
# Input Variables
# =============================================================================
# Defines all input variables for the PostgreSQL HA infrastructure.
# Variables have sensible defaults for the development environment.
# =============================================================================

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "pgha"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must start with a letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS Account ID (used for unique resource naming). Set in terraform.tfvars."
  type        = string
  # No default - must be provided in terraform.tfvars
}

# -----------------------------------------------------------------------------
# Networking Variables
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "admin_ip" {
  description = "IP address or CIDR for SSH access. WARNING: 0.0.0.0/0 allows access from anywhere - use only for testing!"
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.admin_ip, 0)) || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.admin_ip))
    error_message = "Admin IP must be a valid CIDR block (e.g., 192.168.1.1/32 or 0.0.0.0/0)."
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance Variables
# -----------------------------------------------------------------------------

variable "create_key_pair" {
  description = "Whether to create a new key pair. If true, generates a new key pair. If false, uses existing key_name."
  type        = bool
  default     = false
}

variable "key_name" {
  description = "Name of existing AWS key pair. Required if create_key_pair = false."
  type        = string
  default     = ""
}

variable "public_key_path" {
  description = "Path to public key file (e.g., ~/.ssh/id_rsa.pub). If empty and create_key_pair=true, generates new key pair."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for both etcd and Patroni instances"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = can(regex("^t2\\.(micro|small|medium)|t3\\.(micro|small|medium)|t4g\\.(micro|small)$", var.instance_type))
    error_message = "Instance type must be t2.micro, t2.small, t2.medium, t3.micro, t3.small, t3.medium, t4g.micro, or t4g.small."
  }
}

variable "etcd_instance_count" {
  description = "Number of etcd instances (should be odd for quorum: 1, 3, or 5)"
  type        = number
  default     = 3

  validation {
    condition     = var.etcd_instance_count == 1 || var.etcd_instance_count == 3 || var.etcd_instance_count == 5
    error_message = "etcd instance count must be 1, 3, or 5 for proper quorum."
  }
}

variable "patroni_instance_count" {
  description = "Number of Patroni/PostgreSQL instances (1 Primary + N-1 Replicas)"
  type        = number
  default     = 2

  validation {
    condition     = var.patroni_instance_count >= 1 && var.patroni_instance_count <= 5
    error_message = "Patroni instance count must be between 1 and 5."
  }
}

variable "etcd_version" {
  description = "etcd version to install"
  type        = string
  default     = "v3.5.17"

  validation {
    condition     = can(regex("^v3\\.5\\.(1[7-9]|[2-9][0-9])$", var.etcd_version))
    error_message = "etcd version must be v3.5.17 or higher (avoid v3.5.0-3.5.2 due to data corruption bug)."
  }
}

variable "etcd_root_volume_size" {
  description = "Root volume size in GB for etcd instances (minimum 30GB for Amazon Linux 2023)"
  type        = number
  default     = 30

  validation {
    condition     = var.etcd_root_volume_size >= 30 && var.etcd_root_volume_size <= 100
    error_message = "etcd root volume size must be between 30 and 100 GB (AL2023 AMI requires minimum 30GB)."
  }
}

variable "patroni_root_volume_size" {
  description = "Root volume size in GB for Patroni instances (includes PostgreSQL data)"
  type        = number
  default     = 30

  validation {
    condition     = var.patroni_root_volume_size >= 20 && var.patroni_root_volume_size <= 100
    error_message = "Patroni root volume size must be between 20 and 100 GB."
  }
}
