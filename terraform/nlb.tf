# =============================================================================
# Network Load Balancer for PostgreSQL HA
# =============================================================================
# Creates an internal NLB with two target groups:
# - Primary (R/W): Routes to the current Patroni leader via /primary health check
# - Replicas (RO): Routes to replicas via /replica health check
#
# All Patroni instances are registered in both target groups.
# Health checks determine which instances respond to each target group.
# =============================================================================

# -----------------------------------------------------------------------------
# Network Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "postgres" {
  name               = "${local.name_prefix}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nlb"
  })

  depends_on = [aws_instance.patroni]
}

# -----------------------------------------------------------------------------
# Target Group: Primary (R/W Connections)
# -----------------------------------------------------------------------------
# Routes traffic to the current Patroni leader.
# Health check uses Patroni API /primary endpoint.
# Only the leader responds 200 OK to /primary.

resource "aws_lb_target_group" "primary" {
  name        = "${local.name_prefix}-primary"
  port        = 5432
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "8008"
    path                = "/primary"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-primary"
    Role = "primary"
  })
}

# -----------------------------------------------------------------------------
# Target Group: Replicas (RO Connections)
# -----------------------------------------------------------------------------
# Routes traffic to Patroni replicas for read-only queries.
# Health check uses Patroni API /replica endpoint.
# Only healthy replicas respond 200 OK to /replica.

resource "aws_lb_target_group" "replicas" {
  name        = "${local.name_prefix}-replicas"
  port        = 5432
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "8008"
    path                = "/replica"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-replicas"
    Role = "replicas"
  })
}

# -----------------------------------------------------------------------------
# Listener: R/W (Port 5432)
# -----------------------------------------------------------------------------
# Forwards read-write connections to the primary target group.

resource "aws_lb_listener" "postgres_rw" {
  load_balancer_arn = aws_lb.postgres.arn
  port              = 5432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-listener-rw"
  })
}

# -----------------------------------------------------------------------------
# Listener: RO (Port 5433)
# -----------------------------------------------------------------------------
# Forwards read-only connections to the replicas target group.

resource "aws_lb_listener" "postgres_ro" {
  load_balancer_arn = aws_lb.postgres.arn
  port              = 5433
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.replicas.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-listener-ro"
  })
}

# -----------------------------------------------------------------------------
# Target Group Attachments: Primary
# -----------------------------------------------------------------------------
# Registers all Patroni instances in the primary target group.
# The health check (/primary) ensures only the leader receives traffic.

resource "aws_lb_target_group_attachment" "patroni_primary" {
  for_each = local.patroni_instances

  target_group_arn = aws_lb_target_group.primary.arn
  target_id        = aws_instance.patroni[each.key].id
  port             = 5432
}

# -----------------------------------------------------------------------------
# Target Group Attachments: Replicas
# -----------------------------------------------------------------------------
# Registers all Patroni instances in the replicas target group.
# The health check (/replica) ensures only replicas receive traffic.

resource "aws_lb_target_group_attachment" "patroni_replicas" {
  for_each = local.patroni_instances

  target_group_arn = aws_lb_target_group.replicas.arn
  target_id        = aws_instance.patroni[each.key].id
  port             = 5432
}

# -----------------------------------------------------------------------------
# Target Group: PgBouncer (Connection Pooling)
# -----------------------------------------------------------------------------
# Routes traffic to PgBouncer for connection pooling.
# All Patroni nodes run PgBouncer locally, forwarding to local PostgreSQL.
# TCP health check verifies PgBouncer is accepting connections.

resource "aws_lb_target_group" "pgbouncer" {
  name        = "${local.name_prefix}-pgbouncer"
  port        = 6432
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "6432"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-pgbouncer"
    Role = "pgbouncer"
  })
}

# -----------------------------------------------------------------------------
# Listener: PgBouncer (Port 6432)
# -----------------------------------------------------------------------------
# Forwards pooled connections to PgBouncer on all Patroni nodes.

resource "aws_lb_listener" "pgbouncer" {
  load_balancer_arn = aws_lb.postgres.arn
  port              = 6432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pgbouncer.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-listener-pgbouncer"
  })
}

# -----------------------------------------------------------------------------
# Target Group Attachments: PgBouncer
# -----------------------------------------------------------------------------
# Registers all Patroni instances in the PgBouncer target group.
# Each node's PgBouncer connects to its local PostgreSQL instance.

resource "aws_lb_target_group_attachment" "patroni_pgbouncer" {
  for_each = local.patroni_instances

  target_group_arn = aws_lb_target_group.pgbouncer.arn
  target_id        = aws_instance.patroni[each.key].id
  port             = 6432
}
