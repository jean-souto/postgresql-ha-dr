#!/bin/bash
# DR Standby PostgreSQL - Warm Standby with Streaming Replication
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

hostnamectl set-hostname ${instance_name}
dnf update -y && dnf install -y jq python3

# Metadata
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
PRIMARY_HOST="${primary_host}"
PGDATA="/var/lib/pgsql/17/data"

# Secrets from SSM
POSTGRES_PASSWORD=$(aws ssm get-parameter --name "/pgha/postgres-password" --with-decryption --query 'Parameter.Value' --output text --region ${primary_region})
REPLICATION_PASSWORD=$(aws ssm get-parameter --name "/pgha/replication-password" --with-decryption --query 'Parameter.Value' --output text --region ${primary_region})

# Install PostgreSQL 17
[ ! -f /etc/redhat-release ] && echo "Red Hat Enterprise Linux release 9.4 (Plow)" > /etc/redhat-release
curl -sLo /tmp/pgdg.rpm https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
rpm -ivh --nodeps /tmp/pgdg.rpm
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/pgdg-redhat-all.repo
dnf clean all && dnf -qy module disable postgresql 2>/dev/null || true
dnf install -y postgresql17-server postgresql17-contrib pgbackrest
mkdir -p $PGDATA /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest
chown -R postgres:postgres /var/lib/pgsql/17 /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest
chmod 700 $PGDATA

# pgBackRest config
cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-type=s3
repo1-s3-bucket=${primary_bucket}
repo1-s3-region=${primary_region}
repo1-s3-endpoint=s3.${primary_region}.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest
repo2-type=s3
repo2-s3-bucket=${pgbackrest_bucket}
repo2-s3-region=${aws_region}
repo2-s3-endpoint=s3.${aws_region}.amazonaws.com
repo2-s3-key-type=auto
repo2-path=/pgbackrest
repo2-retention-full=2
process-max=2
compress-type=lz4
log-level-console=info
log-path=/var/log/pgbackrest
[${pgbackrest_stanza}]
pg1-path=$PGDATA
pg1-port=5432
EOF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf && chmod 640 /etc/pgbackrest/pgbackrest.conf

# .pgpass for replication
cat > /var/lib/pgsql/.pgpass << EOF
$PRIMARY_HOST:5432:*:replicator:$REPLICATION_PASSWORD
*:5432:*:replicator:$REPLICATION_PASSWORD
EOF
chown postgres:postgres /var/lib/pgsql/.pgpass && chmod 600 /var/lib/pgsql/.pgpass

# Init standby script (run manually after VPC peering is active)
cat > /usr/local/bin/init-standby.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
PRIMARY_HOST="${primary_host}"
PGDATA="/var/lib/pgsql/17/data"
REPL_PASS=$(aws ssm get-parameter --name "/pgha/replication-password" --with-decryption --query 'Parameter.Value' --output text --region ${primary_region})
echo "Initializing standby from primary..."
systemctl stop postgresql-17 2>/dev/null || true
rm -rf $PGDATA/*
su - postgres -c "PGPASSWORD='$REPL_PASS' pg_basebackup -h $PRIMARY_HOST -p 5432 -U replicator -D $PGDATA -Fp -Xs -P -R --checkpoint=fast"
# Configure standby
cat >> $PGDATA/postgresql.conf << CONF
listen_addresses = '*'
primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=replicator password=$REPL_PASS application_name=${instance_name}'
hot_standby = on
hot_standby_feedback = on
archive_mode = on
archive_command = 'pgbackrest --stanza=${pgbackrest_stanza} archive-push %p'
restore_command = 'pgbackrest --stanza=${pgbackrest_stanza} archive-get %f "%p"'
shared_buffers = 128MB
CONF
cat > $PGDATA/pg_hba.conf << HBA
local all all peer
host all all 127.0.0.1/32 scram-sha-256
host all all 10.1.0.0/16 scram-sha-256
host replication replicator 10.0.0.0/16 scram-sha-256
host replication replicator 10.1.0.0/16 scram-sha-256
HBA
chown postgres:postgres $PGDATA/postgresql.conf $PGDATA/pg_hba.conf
systemctl start postgresql-17
echo "Standby initialized! Check: psql -c 'SELECT * FROM pg_stat_wal_receiver'"
SCRIPT
chmod +x /usr/local/bin/init-standby.sh

# Promote script
cat > /usr/local/bin/promote-to-primary.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "WARNING: This promotes standby to primary. Only run if primary region is DOWN!"
read -p "Type 'PROMOTE' to continue: " confirm
[ "$confirm" != "PROMOTE" ] && echo "Cancelled." && exit 0
su - postgres -c "pg_ctl promote -D /var/lib/pgsql/17/data"
sleep 5
su - postgres -c "psql -c 'SELECT pg_is_in_recovery()'" | grep -q "f" && echo "Promotion complete!" || echo "ERROR: Check logs"
SCRIPT
chmod +x /usr/local/bin/promote-to-primary.sh

# Check replication script
cat > /usr/local/bin/check-replication.sh << 'SCRIPT'
#!/bin/bash
echo "=== Replication Status ==="
su - postgres -c "psql -c 'SELECT status, received_lsn, sender_host FROM pg_stat_wal_receiver'"
su - postgres -c "psql -c 'SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()'"
SCRIPT
chmod +x /usr/local/bin/check-replication.sh

# Install node_exporter
cd /tmp
curl -sLO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xzf node_exporter-1.8.2.linux-amd64.tar.gz
cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now node_exporter

# postgres_exporter (enabled but not started until PG runs)
curl -sLO https://github.com/prometheus-community/postgres_exporter/releases/download/v0.16.0/postgres_exporter-0.16.0.linux-amd64.tar.gz
tar xzf postgres_exporter-0.16.0.linux-amd64.tar.gz
cp postgres_exporter-0.16.0.linux-amd64/postgres_exporter /usr/local/bin/
useradd --no-create-home --shell /bin/false postgres_exporter 2>/dev/null || true
cat > /etc/systemd/system/postgres_exporter.service << EOF
[Unit]
Description=Postgres Exporter
After=postgresql-17.service
[Service]
User=postgres_exporter
Environment=DATA_SOURCE_NAME=postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres?sslmode=disable
ExecStart=/usr/local/bin/postgres_exporter
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable postgres_exporter

systemctl enable postgresql-17

echo ""
echo "==========================================="
echo "  DR STANDBY READY - MANUAL INIT REQUIRED"
echo "==========================================="
echo "Run /usr/local/bin/init-standby.sh after VPC peering is active"
