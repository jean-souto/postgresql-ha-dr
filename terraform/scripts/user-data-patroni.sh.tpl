#!/bin/bash
# =============================================================================
# Patroni/PostgreSQL Bootstrap Script
# =============================================================================
# Installs and configures PostgreSQL 17, Patroni, and PgBouncer.
# Template variables are injected by Terraform templatefile().
# =============================================================================

set -euxo pipefail

# Log all output
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Patroni bootstrap ==="
echo "Instance Name: ${instance_name}"
echo "Cluster Name: ${cluster_name}"

# -----------------------------------------------------------------------------
# System Configuration
# -----------------------------------------------------------------------------

# Set hostname
hostnamectl set-hostname ${instance_name}

# Update system packages
dnf update -y

# Install required packages
dnf install -y jq python3 python3-pip gcc python3-devel

# -----------------------------------------------------------------------------
# Get Instance Metadata
# -----------------------------------------------------------------------------

# Get IMDSv2 token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Get private IP
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Private IP: $PRIVATE_IP"

# -----------------------------------------------------------------------------
# Fetch Secrets from SSM Parameter Store
# -----------------------------------------------------------------------------

echo "=== Fetching secrets from SSM ==="

POSTGRES_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/postgres-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

REPLICATION_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/replication-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

PGBOUNCER_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/pgbouncer-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

PATRONI_API_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/patroni-api-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

echo "Secrets fetched successfully"

# -----------------------------------------------------------------------------
# Install PostgreSQL 17
# -----------------------------------------------------------------------------

echo "=== Installing PostgreSQL 17 ==="

# Amazon Linux 2023 compatibility: Create /etc/redhat-release for PGDG repo
# AL2023 is Fedora-based but lacks this file that PGDG expects
if [ ! -f /etc/redhat-release ]; then
  echo "Red Hat Enterprise Linux release 9.4 (Plow)" > /etc/redhat-release
fi

# Download and install PGDG repo RPM bypassing dependency check
# The RPM requires /etc/redhat-release but we just created it above
curl -Lo /tmp/pgdg-repo.rpm https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
rpm -ivh --nodeps /tmp/pgdg-repo.rpm

# Fix PGDG repo URLs: Amazon Linux 2023 reports $releasever as "2023" but we need "9"
# This replaces the variable with hardcoded "9" in all PGDG repo files
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/pgdg-redhat-all.repo

# Clean dnf cache to pick up the corrected repo URLs
dnf clean all

# Disable built-in PostgreSQL module (ignore errors if not present)
dnf -qy module disable postgresql 2>/dev/null || true

# Install PostgreSQL 17
dnf install -y postgresql17-server postgresql17-contrib

# Create data directory with correct permissions
# PostgreSQL requires 0700 on data directory
mkdir -p /var/lib/pgsql/17/data
chown -R postgres:postgres /var/lib/pgsql/17
chmod 700 /var/lib/pgsql/17/data

# -----------------------------------------------------------------------------
# Install pgBackRest
# -----------------------------------------------------------------------------

echo "=== Installing pgBackRest ==="

# Install pgBackRest from PGDG repository
dnf install -y pgbackrest

# Create pgBackRest directories
mkdir -p /var/log/pgbackrest
mkdir -p /var/lib/pgbackrest
mkdir -p /etc/pgbackrest
chown -R postgres:postgres /var/log/pgbackrest
chown -R postgres:postgres /var/lib/pgbackrest
chown -R postgres:postgres /etc/pgbackrest

# Configure pgBackRest for S3
cat > /etc/pgbackrest/pgbackrest.conf << 'PGBRCFG'
[global]
# S3 Repository Configuration
repo1-type=s3
repo1-s3-bucket=${pgbackrest_bucket}
repo1-s3-region=${aws_region}
repo1-s3-endpoint=s3.${aws_region}.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest

# Backup Retention Policy
# Keep 2 full backups and 7 differential backups
repo1-retention-full=2
repo1-retention-diff=7

# Performance settings
process-max=2
compress-type=lz4
compress-level=6

# Logging
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

# Backup settings
start-fast=y
delta=y
stop-auto=y
archive-async=y
spool-path=/var/lib/pgbackrest

[${pgbackrest_stanza}]
pg1-path=/var/lib/pgsql/17/data
pg1-port=5432
pg1-user=postgres
PGBRCFG

chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
chmod 640 /etc/pgbackrest/pgbackrest.conf

echo "pgBackRest configured for S3 bucket: ${pgbackrest_bucket}"

# -----------------------------------------------------------------------------
# Install Patroni
# -----------------------------------------------------------------------------

echo "=== Installing Patroni ==="

pip3 install patroni[etcd3] psycopg2-binary

# Create Patroni directories
mkdir -p /etc/patroni
mkdir -p /var/log/patroni
chown postgres:postgres /var/log/patroni

# -----------------------------------------------------------------------------
# Configure Patroni
# -----------------------------------------------------------------------------

echo "=== Configuring Patroni ==="

cat > /etc/patroni/patroni.yml << EOF
scope: ${cluster_name}
name: ${instance_name}

restapi:
  listen: 0.0.0.0:8008
  connect_address: $${PRIVATE_IP}:8008
  authentication:
    username: admin
    password: '$${PATRONI_API_PASSWORD}'

etcd3:
  hosts: ${etcd_hosts}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # Memory settings for t2.micro (1GB RAM)
        shared_buffers: 128MB
        effective_cache_size: 384MB
        work_mem: 4MB
        maintenance_work_mem: 64MB

        # WAL settings
        wal_level: replica
        hot_standby: on
        max_wal_senders: 5
        max_replication_slots: 5
        wal_keep_size: 512MB

        # WAL Archiving with pgBackRest (for PITR)
        archive_mode: 'on'
        archive_command: 'pgbackrest --stanza=${pgbackrest_stanza} archive-push %p'
        archive_timeout: 60

        # Logging
        logging_collector: on
        log_directory: /var/log/postgresql
        log_filename: 'postgresql-%Y-%m-%d.log'
        log_rotation_age: 1d
        log_rotation_size: 100MB
        log_min_duration_statement: 1000
        log_checkpoints: on
        log_connections: on
        log_disconnections: on
        log_lock_waits: on

      # Recovery configuration for PITR with pgBackRest
      recovery_conf:
        restore_command: 'pgbackrest --stanza=${pgbackrest_stanza} archive-get %f %p'

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local   all             all                                     trust
    - host    all             all             127.0.0.1/32            scram-sha-256
    - host    all             all             0.0.0.0/0               scram-sha-256
    - host    replication     replicator      0.0.0.0/0               scram-sha-256

  users:
    admin:
      password: '$${POSTGRES_PASSWORD}'
      options:
        - superuser
        - createrole
        - createdb
    replicator:
      password: '$${REPLICATION_PASSWORD}'
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $${PRIVATE_IP}:5432
  data_dir: /var/lib/pgsql/17/data
  bin_dir: /usr/bin
  pgpass: /var/lib/pgsql/.pgpass
  authentication:
    superuser:
      username: postgres
      password: '$${POSTGRES_PASSWORD}'
    replication:
      username: replicator
      password: '$${REPLICATION_PASSWORD}'
    rewind:
      username: postgres
      password: '$${POSTGRES_PASSWORD}'

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml

# Create PostgreSQL log directory
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# -----------------------------------------------------------------------------
# Create Patroni systemd Service
# -----------------------------------------------------------------------------

cat > /etc/systemd/system/patroni.service << 'EOF'
[Unit]
Description=Patroni PostgreSQL Cluster Manager
Documentation=https://patroni.readthedocs.io/
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Install PgBouncer
# -----------------------------------------------------------------------------

echo "=== Installing PgBouncer ==="

dnf install -y pgbouncer

# Configure PgBouncer
cat > /etc/pgbouncer/pgbouncer.ini << EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = pgbouncer
pool_mode = transaction
ignore_startup_parameters = extra_float_digits
max_client_conn = 100
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_lifetime = 3600
server_idle_timeout = 600
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF

# Create PgBouncer userlist
cat > /etc/pgbouncer/userlist.txt << EOF
"postgres" "$${POSTGRES_PASSWORD}"
"pgbouncer" "$${PGBOUNCER_PASSWORD}"
"admin" "$${POSTGRES_PASSWORD}"
EOF

chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt

# -----------------------------------------------------------------------------
# Start Services
# -----------------------------------------------------------------------------

echo "=== Starting services ==="

systemctl daemon-reload

# Start Patroni
systemctl enable patroni
systemctl start patroni

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
sleep 30

# Start PgBouncer
systemctl enable pgbouncer
systemctl start pgbouncer

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------

echo "=== Verifying installation ==="

# Check Patroni status
curl -s http://localhost:8008/patroni || echo "Patroni API not ready yet"

# Check PostgreSQL is running
su - postgres -c "/usr/bin/pg_isready -h localhost -p 5432" || echo "PostgreSQL not ready yet"

# -----------------------------------------------------------------------------
# Initialize pgBackRest (only on primary)
# -----------------------------------------------------------------------------

echo "=== Initializing pgBackRest ==="

# Wait a bit more for cluster to stabilize
sleep 10

# Check if this node is the primary
IS_PRIMARY=$(curl -s http://localhost:8008/patroni | jq -r '.role' 2>/dev/null || echo "unknown")

if [ "$IS_PRIMARY" = "master" ] || [ "$IS_PRIMARY" = "primary" ]; then
    echo "This is the primary node - initializing pgBackRest stanza"

    # Create stanza (only needs to be done once, on primary)
    su - postgres -c "pgbackrest --stanza=${pgbackrest_stanza} stanza-create" || {
        echo "Stanza may already exist or failed to create"
    }

    # Verify stanza configuration
    su - postgres -c "pgbackrest --stanza=${pgbackrest_stanza} check" || {
        echo "pgBackRest check failed - will retry later"
    }

    # Show stanza info
    su - postgres -c "pgbackrest --stanza=${pgbackrest_stanza} info" || true

    echo "pgBackRest stanza initialized successfully"
else
    echo "This is a replica node (role: $IS_PRIMARY) - skipping stanza creation"
    echo "pgBackRest will be configured but stanza is managed by primary"
fi

# -----------------------------------------------------------------------------
# Install Prometheus Exporters
# -----------------------------------------------------------------------------

echo "=== Installing Prometheus exporters ==="

NODE_EXPORTER_VERSION="1.7.0"
POSTGRES_EXPORTER_VERSION="0.15.0"

# Install node_exporter
cd /tmp
curl -sLO https://github.com/prometheus/node_exporter/releases/download/v$${NODE_EXPORTER_VERSION}/node_exporter-$${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf node_exporter-$${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
cp node_exporter-$${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

cat > /etc/systemd/system/node_exporter.service << 'NODEEXPORTER'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
NODEEXPORTER

# Install postgres_exporter
curl -sLO https://github.com/prometheus-community/postgres_exporter/releases/download/v$${POSTGRES_EXPORTER_VERSION}/postgres_exporter-$${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf postgres_exporter-$${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
cp postgres_exporter-$${POSTGRES_EXPORTER_VERSION}.linux-amd64/postgres_exporter /usr/local/bin/
chmod +x /usr/local/bin/postgres_exporter

echo 'DATA_SOURCE_NAME=host=/var/run/postgresql user=postgres sslmode=disable' > /etc/postgres_exporter.env

cat > /etc/systemd/system/postgres_exporter.service << 'PGEXPORTER'
[Unit]
Description=Prometheus PostgreSQL Exporter
Wants=network-online.target
After=network-online.target patroni.service

[Service]
User=postgres
Group=postgres
Type=simple
EnvironmentFile=/etc/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter

[Install]
WantedBy=multi-user.target
PGEXPORTER

# Install pgbouncer_exporter
PGBOUNCER_EXPORTER_VERSION="0.11.0"

curl -sLO https://github.com/prometheus-community/pgbouncer_exporter/releases/download/v$${PGBOUNCER_EXPORTER_VERSION}/pgbouncer_exporter-$${PGBOUNCER_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf pgbouncer_exporter-$${PGBOUNCER_EXPORTER_VERSION}.linux-amd64.tar.gz
cp pgbouncer_exporter-$${PGBOUNCER_EXPORTER_VERSION}.linux-amd64/pgbouncer_exporter /usr/local/bin/
chmod +x /usr/local/bin/pgbouncer_exporter

# URL-encode password for connection string and escape % for systemd
ENCODED_PGBOUNCER_PWD=$(python3 -c "import urllib.parse; import sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$${PGBOUNCER_PASSWORD}")
ESCAPED_PGBOUNCER_PWD=$(echo "$ENCODED_PGBOUNCER_PWD" | sed 's/%/%%/g')

cat > /etc/systemd/system/pgbouncer_exporter.service << PGBOUNCEREXPORTER
[Unit]
Description=Prometheus PgBouncer Exporter
Wants=network-online.target
After=network-online.target pgbouncer.service

[Service]
User=postgres
Group=postgres
Type=simple
ExecStart=/usr/local/bin/pgbouncer_exporter --pgBouncer.connectionString=postgres://pgbouncer:$ESCAPED_PGBOUNCER_PWD@localhost:6432/pgbouncer?sslmode=disable

[Install]
WantedBy=multi-user.target
PGBOUNCEREXPORTER

# Start exporters
systemctl daemon-reload
systemctl enable node_exporter postgres_exporter pgbouncer_exporter
systemctl start node_exporter postgres_exporter pgbouncer_exporter

echo "Prometheus exporters installed (node, postgres, pgbouncer)"

echo "=== Patroni bootstrap completed ==="
