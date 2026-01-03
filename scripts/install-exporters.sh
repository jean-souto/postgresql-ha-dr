#!/bin/bash
# =============================================================================
# Install Prometheus Exporters on Patroni Nodes
# =============================================================================
# Run this on each Patroni node via SSH
# Usage: sudo bash install-exporters.sh

set -euxo pipefail

NODE_EXPORTER_VERSION="1.7.0"
POSTGRES_EXPORTER_VERSION="0.15.0"

echo "=== Installing Node Exporter ${NODE_EXPORTER_VERSION} ==="

cd /tmp
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

cat > /etc/systemd/system/node_exporter.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

echo "=== Installing Postgres Exporter ${POSTGRES_EXPORTER_VERSION} ==="

cd /tmp
wget -q https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
cp postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64/postgres_exporter /usr/local/bin/
chmod +x /usr/local/bin/postgres_exporter

useradd --no-create-home --shell /bin/false postgres_exporter 2>/dev/null || true

# Connection string for local postgres
cat > /etc/postgres_exporter.env << 'EOF'
DATA_SOURCE_NAME="host=/var/run/postgresql user=postgres sslmode=disable"
EOF

cat > /etc/systemd/system/postgres_exporter.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable postgres_exporter
systemctl start postgres_exporter

echo "=== Verifying services ==="
systemctl status node_exporter --no-pager
systemctl status postgres_exporter --no-pager

echo "=== Testing endpoints ==="
curl -s http://localhost:9100/metrics | head -5
curl -s http://localhost:9187/metrics | head -5

echo "=== Exporters installed successfully ==="
