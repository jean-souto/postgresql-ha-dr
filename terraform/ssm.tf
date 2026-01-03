# =============================================================================
# SSM Parameter Store
# =============================================================================
# Stores sensitive configuration values as SecureString parameters.
# Uses AWS-managed KMS key (aws/ssm) for encryption - free tier.
# =============================================================================

# -----------------------------------------------------------------------------
# Random Passwords
# -----------------------------------------------------------------------------

resource "random_password" "postgres" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "replication" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "pgbouncer" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "patroni_api" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# -----------------------------------------------------------------------------
# SSM Parameters (SecureString)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "postgres_password" {
  name        = "/pgha/postgres-password"
  description = "PostgreSQL superuser password"
  type        = "SecureString"
  value       = random_password.postgres.result

  # Uses AWS-managed key (alias/aws/ssm) by default - free

  tags = local.common_tags
}

resource "aws_ssm_parameter" "replication_password" {
  name        = "/pgha/replication-password"
  description = "PostgreSQL replication user password"
  type        = "SecureString"
  value       = random_password.replication.result

  tags = local.common_tags
}

resource "aws_ssm_parameter" "pgbouncer_password" {
  name        = "/pgha/pgbouncer-password"
  description = "PgBouncer admin password"
  type        = "SecureString"
  value       = random_password.pgbouncer.result

  tags = local.common_tags
}

resource "aws_ssm_parameter" "patroni_api_password" {
  name        = "/pgha/patroni-api-password"
  description = "Patroni REST API password"
  type        = "SecureString"
  value       = random_password.patroni_api.result

  tags = local.common_tags
}
