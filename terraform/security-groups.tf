# =============================================================================
# Security Groups
# =============================================================================
# Defines security groups for Patroni/PostgreSQL and etcd clusters.
# Follows least-privilege principle with specific ingress rules.
# =============================================================================

# -----------------------------------------------------------------------------
# Security Group: Patroni/PostgreSQL
# -----------------------------------------------------------------------------

resource "aws_security_group" "patroni" {
  name        = "${local.name_prefix}-patroni-sg"
  description = "Security group for Patroni/PostgreSQL instances"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-patroni-sg"
  })
}

# PostgreSQL from VPC (via NLB - NLB preserves source IPs)
resource "aws_vpc_security_group_ingress_rule" "patroni_postgres" {
  security_group_id = aws_security_group.patroni.id
  description       = "PostgreSQL from VPC (via NLB)"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = aws_vpc.main.cidr_block
}

# PgBouncer from VPC
resource "aws_vpc_security_group_ingress_rule" "patroni_pgbouncer" {
  security_group_id = aws_security_group.patroni.id
  description       = "PgBouncer from VPC"
  from_port         = 6432
  to_port           = 6432
  ip_protocol       = "tcp"
  cidr_ipv4         = aws_vpc.main.cidr_block
}

# Patroni API for NLB health checks
resource "aws_vpc_security_group_ingress_rule" "patroni_api" {
  security_group_id = aws_security_group.patroni.id
  description       = "Patroni API for health checks"
  from_port         = 8008
  to_port           = 8008
  ip_protocol       = "tcp"
  cidr_ipv4         = aws_vpc.main.cidr_block
}

# SSH from Bastion only (not directly from admin IP)
resource "aws_vpc_security_group_ingress_rule" "patroni_ssh" {
  security_group_id            = aws_security_group.patroni.id
  description                  = "SSH from Bastion host"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion.id
}

# PostgreSQL replication between Patroni nodes (self-referencing)
resource "aws_vpc_security_group_ingress_rule" "patroni_replication" {
  security_group_id            = aws_security_group.patroni.id
  description                  = "PostgreSQL replication between Patroni nodes"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.patroni.id
}

# Node exporter metrics from Monitoring (Prometheus)
resource "aws_vpc_security_group_ingress_rule" "patroni_node_exporter" {
  count                        = var.enable_monitoring ? 1 : 0
  security_group_id            = aws_security_group.patroni.id
  description                  = "Node exporter metrics from Monitoring"
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id
}

# Postgres exporter metrics from Monitoring (Prometheus)
resource "aws_vpc_security_group_ingress_rule" "patroni_postgres_exporter" {
  count                        = var.enable_monitoring ? 1 : 0
  security_group_id            = aws_security_group.patroni.id
  description                  = "Postgres exporter metrics from Monitoring"
  from_port                    = 9187
  to_port                      = 9187
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id
}

# PgBouncer exporter metrics from Monitoring (Prometheus)
resource "aws_vpc_security_group_ingress_rule" "patroni_pgbouncer_exporter" {
  count                        = var.enable_monitoring ? 1 : 0
  security_group_id            = aws_security_group.patroni.id
  description                  = "PgBouncer exporter metrics from Monitoring"
  from_port                    = 9127
  to_port                      = 9127
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id
}

# All outbound traffic
resource "aws_vpc_security_group_egress_rule" "patroni_all_outbound" {
  security_group_id = aws_security_group.patroni.id
  description       = "All outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Security Group: etcd
# -----------------------------------------------------------------------------

resource "aws_security_group" "etcd" {
  name        = "${local.name_prefix}-etcd-sg"
  description = "Security group for etcd cluster"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-etcd-sg"
  })
}

# etcd Client API from Patroni instances
resource "aws_vpc_security_group_ingress_rule" "etcd_client_patroni" {
  security_group_id            = aws_security_group.etcd.id
  description                  = "etcd client API from Patroni"
  from_port                    = 2379
  to_port                      = 2379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.patroni.id
}

# etcd Client API from other etcd nodes (for etcdctl and health checks)
resource "aws_vpc_security_group_ingress_rule" "etcd_client_self" {
  security_group_id            = aws_security_group.etcd.id
  description                  = "etcd client API from other etcd nodes"
  from_port                    = 2379
  to_port                      = 2379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.etcd.id
}

# etcd Peer communication (self-referencing)
resource "aws_vpc_security_group_ingress_rule" "etcd_peer" {
  security_group_id            = aws_security_group.etcd.id
  description                  = "etcd peer communication"
  from_port                    = 2380
  to_port                      = 2380
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.etcd.id
}

# SSH from Bastion only (not directly from admin IP)
resource "aws_vpc_security_group_ingress_rule" "etcd_ssh" {
  security_group_id            = aws_security_group.etcd.id
  description                  = "SSH from Bastion host"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion.id
}

# etcd metrics from Monitoring (Prometheus)
resource "aws_vpc_security_group_ingress_rule" "etcd_metrics_monitoring" {
  count                        = var.enable_monitoring ? 1 : 0
  security_group_id            = aws_security_group.etcd.id
  description                  = "etcd metrics from Monitoring"
  from_port                    = 2379
  to_port                      = 2379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id
}

# All outbound traffic
resource "aws_vpc_security_group_egress_rule" "etcd_all_outbound" {
  security_group_id = aws_security_group.etcd.id
  description       = "All outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
