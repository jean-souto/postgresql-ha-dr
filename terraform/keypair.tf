# =============================================================================
# EC2 Key Pair Management
# =============================================================================
# Handles SSH key pair creation for EC2 instances.
#
# Options:
#   1. Auto-generate: Set create_key_pair = true (generates new key pair)
#   2. Use existing: Set create_key_pair = false and provide key_name
#   3. Provide public key: Set create_key_pair = true and public_key_path
# =============================================================================

# Generate a new RSA key pair if create_key_pair is true and no public key provided
resource "tls_private_key" "generated" {
  count     = var.create_key_pair && var.public_key_path == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create key pair from generated key
resource "aws_key_pair" "generated" {
  count      = var.create_key_pair && var.public_key_path == "" ? 1 : 0
  key_name   = "${local.name_prefix}-key"
  public_key = tls_private_key.generated[0].public_key_openssh

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-key"
  })
}

# Create key pair from provided public key file
resource "aws_key_pair" "provided" {
  count      = var.create_key_pair && var.public_key_path != "" ? 1 : 0
  key_name   = "${local.name_prefix}-key"
  public_key = file(var.public_key_path)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-key"
  })
}

# Save generated private key to local file
resource "local_file" "private_key" {
  count           = var.create_key_pair && var.public_key_path == "" ? 1 : 0
  content         = tls_private_key.generated[0].private_key_pem
  filename        = "${path.module}/../keys/${local.name_prefix}-key.pem"
  file_permission = "0400"
}

# Local for the effective key name to use
locals {
  effective_key_name = var.create_key_pair ? (
    var.public_key_path != "" ? aws_key_pair.provided[0].key_name : aws_key_pair.generated[0].key_name
  ) : var.key_name
}

# =============================================================================
# Outputs
# =============================================================================

output "key_pair_name" {
  description = "Name of the key pair used for EC2 instances"
  value       = local.effective_key_name
}

output "private_key_path" {
  description = "Path to the generated private key file (if auto-generated)"
  value       = var.create_key_pair && var.public_key_path == "" ? local_file.private_key[0].filename : "N/A (using existing key)"
}

output "private_key_pem" {
  description = "Generated private key in PEM format (sensitive)"
  value       = var.create_key_pair && var.public_key_path == "" ? tls_private_key.generated[0].private_key_pem : null
  sensitive   = true
}
