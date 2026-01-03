#!/bin/bash
# =============================================================================
# Monitoring Stack Bootstrap Script
# =============================================================================
# Installs Prometheus, Grafana, and Alertmanager
# =============================================================================

set -euxo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Monitoring Stack Bootstrap ==="

# -----------------------------------------------------------------------------
# System Configuration
# -----------------------------------------------------------------------------

hostnamectl set-hostname monitoring
dnf update -y
dnf install -y jq wget tar

# -----------------------------------------------------------------------------
# Create Users
# -----------------------------------------------------------------------------

useradd --no-create-home --shell /bin/false prometheus || true
useradd --no-create-home --shell /bin/false alertmanager || true

# -----------------------------------------------------------------------------
# Install Prometheus
# -----------------------------------------------------------------------------

echo "=== Installing Prometheus ${prometheus_version} ==="

cd /tmp
wget https://github.com/prometheus/prometheus/releases/download/v${prometheus_version}/prometheus-${prometheus_version}.linux-amd64.tar.gz
tar xzf prometheus-${prometheus_version}.linux-amd64.tar.gz
cd prometheus-${prometheus_version}.linux-amd64

cp prometheus /usr/local/bin/
cp promtool /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

mkdir -p /etc/prometheus /var/lib/prometheus
cp -r consoles console_libraries /etc/prometheus/
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Prometheus configuration
cat > /etc/prometheus/prometheus.yml << 'PROMCFG'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - localhost:9093

rule_files:
  - "/etc/prometheus/rules/*.yml"

scrape_configs:
  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # PostgreSQL (via postgres_exporter)
  - job_name: 'postgresql'
    static_configs:
      - targets: [${postgres_targets}]

  # Node metrics (via node_exporter)
  - job_name: 'node'
    static_configs:
      - targets: [${node_targets}]

  # Patroni API
  - job_name: 'patroni'
    static_configs:
      - targets: [${patroni_targets}]
    metrics_path: /metrics

  # etcd
  - job_name: 'etcd'
    static_configs:
      - targets: [${etcd_targets}]

  # PgBouncer metrics (via pgbouncer_exporter)
  - job_name: 'pgbouncer'
    static_configs:
      - targets: [${pgbouncer_targets}]
PROMCFG

# Create rules directory
mkdir -p /etc/prometheus/rules

# Alert rules
cat > /etc/prometheus/rules/postgresql.yml << 'ALERTRULES'
groups:
  - name: postgresql
    rules:
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL instance down"
          description: "PostgreSQL instance {{ $labels.instance }} is down"

      - alert: PostgreSQLHighConnections
        expr: pg_stat_activity_count / pg_settings_max_connections * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High PostgreSQL connections"
          description: "PostgreSQL connection usage is {{ $value }}%"

      - alert: PostgreSQLReplicationLag
        expr: pg_replication_lag > 60
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL replication lag"
          description: "Replication lag is {{ $value }} seconds"

      - alert: PostgreSQLDeadLocks
        expr: rate(pg_stat_database_deadlocks[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL deadlocks detected"
          description: "Deadlocks detected on {{ $labels.instance }}"

  - name: patroni
    rules:
      - alert: PatroniNoPrimary
        expr: sum(patroni_primary) == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "No Patroni primary node"
          description: "No primary node found in Patroni cluster ${cluster_name}"

      - alert: PatroniMultiplePrimaries
        expr: sum(patroni_primary) > 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Multiple Patroni primaries detected"
          description: "Split-brain scenario: {{ $value }} primaries detected"

      - alert: PatroniReplicaDown
        expr: sum(patroni_replica) < 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Patroni replica count low"
          description: "Only {{ $value }} replicas available"

  - name: infrastructure
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage"
          description: "CPU usage is {{ $value }}% on {{ $labels.instance }}"

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage"
          description: "Memory usage is {{ $value }}% on {{ $labels.instance }}"

      - alert: DiskSpaceLow
        expr: (1 - (node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes{fstype!="tmpfs"})) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk space low"
          description: "Disk usage is {{ $value }}% on {{ $labels.instance }}"
ALERTRULES

chown -R prometheus:prometheus /etc/prometheus

# Prometheus systemd service
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time=15d \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.enable-lifecycle

Restart=always

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Install Alertmanager
# -----------------------------------------------------------------------------

echo "=== Installing Alertmanager ${alertmanager_version} ==="

cd /tmp
wget https://github.com/prometheus/alertmanager/releases/download/v${alertmanager_version}/alertmanager-${alertmanager_version}.linux-amd64.tar.gz
tar xzf alertmanager-${alertmanager_version}.linux-amd64.tar.gz
cd alertmanager-${alertmanager_version}.linux-amd64

cp alertmanager /usr/local/bin/
cp amtool /usr/local/bin/
chown alertmanager:alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool

mkdir -p /etc/alertmanager /var/lib/alertmanager
chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

# Alertmanager configuration
cat > /etc/alertmanager/alertmanager.yml << EOF
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'sns-notifications'

  routes:
    - match:
        severity: critical
      receiver: 'sns-notifications'
      repeat_interval: 1h

receivers:
  - name: 'sns-notifications'
    sns_configs:
      - topic_arn: '${sns_topic_arn}'
        sigv4:
          region: '${aws_region}'
        send_resolved: true
        message: |
          {{ range .Alerts }}
          Alert: {{ .Labels.alertname }}
          Severity: {{ .Labels.severity }}
          Instance: {{ .Labels.instance }}
          Description: {{ .Annotations.description }}
          {{ end }}
EOF

chown alertmanager:alertmanager /etc/alertmanager/alertmanager.yml

# Alertmanager systemd service
cat > /etc/systemd/system/alertmanager.service << 'EOF'
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager

Restart=always

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Install Grafana
# -----------------------------------------------------------------------------

echo "=== Installing Grafana ==="

cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y grafana

# Configure Grafana datasource
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
EOF

# Grafana dashboard provisioning
mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/default.yml << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EOF

mkdir -p /var/lib/grafana/dashboards
chown -R grafana:grafana /var/lib/grafana

# PostgreSQL HA/DR Overview Dashboard (Complete - 31 panels)
cat > /var/lib/grafana/dashboards/postgresql.json << 'DASHBOARD'
{
  "id": null,
  "uid": "pgha-overview",
  "title": "PostgreSQL HA/DR Overview",
  "tags": ["postgresql", "patroni", "ha", "dr", "pgbouncer"],
  "timezone": "browser",
  "schemaVersion": 30,
  "version": 2,
  "refresh": "10s",
  "panels": [
    {"id": 1, "title": "Cluster Health", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 0, "y": 0}, "targets": [{"expr": "sum(pg_up)", "legendFormat": "Nodes Up"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 1}, {"color": "green", "value": 2}]}, "mappings": [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "1 Node", "color": "yellow"}, "2": {"text": "2 Nodes", "color": "green"}}}]}}},
    {"id": 2, "title": "Current Leader", "description": "Shows the current primary node name", "type": "stat", "gridPos": {"h": 4, "w": 5, "x": 4, "y": 0}, "targets": [{"expr": "topk(1, patroni_primary == 1)", "legendFormat": "{{name}}", "instant": true}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]}, "displayName": "Primary Node"}}, "options": {"reduceOptions": {"values": false, "calcs": ["last"], "fields": ""}, "orientation": "horizontal", "textMode": "name", "colorMode": "background", "graphMode": "none"}},
    {"id": 3, "title": "Replica Nodes", "type": "stat", "gridPos": {"h": 4, "w": 3, "x": 9, "y": 0}, "targets": [{"expr": "sum(patroni_replica and on(instance) up{job=\"patroni\"} == 1)", "legendFormat": "Replicas"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "green", "value": 1}]}}}},
    {"id": 4, "title": "Database Size", "description": "Size of each database", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 12, "y": 0}, "targets": [{"expr": "max(pg_database_size_bytes{datname=\"postgres\"}) by (datname)", "legendFormat": "{{datname}}"}], "fieldConfig": {"defaults": {"unit": "bytes"}}},
    {"id": 5, "title": "Active Connections", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 16, "y": 0}, "targets": [{"expr": "sum(pg_stat_activity_count)", "legendFormat": "Connections"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 50}, {"color": "red", "value": 90}]}}}},
    {"id": 6, "title": "Replication Lag", "description": "Replication lag in seconds (0 = fully synced)", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 20, "y": 0}, "targets": [{"expr": "max(pg_replication_lag_seconds)", "legendFormat": "Lag"}], "fieldConfig": {"defaults": {"unit": "s", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 5}, {"color": "red", "value": 30}]}, "noValue": "0s (synced)"}}},
    {"id": 7, "title": "Patroni Node Status", "description": "Status of each Patroni node (Primary/Replica)", "type": "table", "gridPos": {"h": 4, "w": 12, "x": 0, "y": 4}, "targets": [{"expr": "patroni_postgres_running", "legendFormat": "{{name}}", "format": "table", "instant": true, "refId": "A"}, {"expr": "patroni_primary", "legendFormat": "{{name}}", "format": "table", "instant": true, "refId": "B"}, {"expr": "patroni_postgres_timeline", "legendFormat": "{{name}}", "format": "table", "instant": true, "refId": "C"}], "transformations": [{"id": "merge"}, {"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true, "scope": true}, "renameByName": {"name": "Node", "instance": "Endpoint", "Value #A": "Running", "Value #B": "Primary", "Value #C": "Timeline"}}}], "fieldConfig": {"overrides": [{"matcher": {"id": "byName", "options": "Running"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}]}]}, {"matcher": {"id": "byName", "options": "Primary"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "Replica", "color": "blue"}, "1": {"text": "Primary", "color": "green"}}}]}]}]}},
    {"id": 8, "title": "WAL Archive Status", "description": "Time since last WAL archive (backup health)", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 12, "y": 4}, "targets": [{"expr": "max(pg_stat_archiver_last_archive_age)", "legendFormat": "Archive Age"}], "fieldConfig": {"defaults": {"unit": "s", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 300}, {"color": "red", "value": 600}]}, "noValue": "No archives"}}},
    {"id": 9, "title": "Archive Success/Fail", "description": "WAL archiving counters", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 16, "y": 4}, "targets": [{"expr": "max(pg_stat_archiver_archived_count)", "legendFormat": "Archived"}, {"expr": "max(pg_stat_archiver_failed_count)", "legendFormat": "Failed"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]}}}},
    {"id": 10, "title": "Timeline", "description": "PostgreSQL timeline (increments after failover)", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 20, "y": 4}, "targets": [{"expr": "max(patroni_postgres_timeline)", "legendFormat": "Timeline"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}}},
    {"id": 11, "title": "Transactions per Second", "type": "timeseries", "gridPos": {"h": 7, "w": 12, "x": 0, "y": 8}, "targets": [{"expr": "rate(pg_stat_database_xact_commit{datname=\"postgres\"}[1m])", "legendFormat": "Commits/s"}, {"expr": "rate(pg_stat_database_xact_rollback{datname=\"postgres\"}[1m])", "legendFormat": "Rollbacks/s"}], "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 12, "title": "Row Operations per Second", "type": "timeseries", "gridPos": {"h": 7, "w": 12, "x": 12, "y": 8}, "targets": [{"expr": "rate(pg_stat_database_tup_inserted{datname=\"postgres\"}[1m])", "legendFormat": "Inserts/s"}, {"expr": "rate(pg_stat_database_tup_updated{datname=\"postgres\"}[1m])", "legendFormat": "Updates/s"}, {"expr": "rate(pg_stat_database_tup_deleted{datname=\"postgres\"}[1m])", "legendFormat": "Deletes/s"}], "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 13, "title": "CPU Usage (%)", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 0, "y": 15}, "targets": [{"expr": "100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)", "legendFormat": "{{instance}}"}]},
    {"id": 14, "title": "Memory Usage (%)", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 8, "y": 15}, "targets": [{"expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100", "legendFormat": "{{instance}}"}]},
    {"id": 15, "title": "Disk Usage (%)", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 16, "y": 15}, "targets": [{"expr": "(1 - (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})) * 100", "legendFormat": "{{instance}}"}]},
    {"id": 16, "title": "etcd Cluster Health", "type": "stat", "gridPos": {"h": 3, "w": 6, "x": 0, "y": 21}, "targets": [{"expr": "sum(up{job=\"etcd\"})", "legendFormat": "etcd Nodes"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 2}, {"color": "green", "value": 3}]}}}},
    {"id": 17, "title": "Streaming Replicas", "type": "stat", "gridPos": {"h": 3, "w": 6, "x": 6, "y": 21}, "targets": [{"expr": "sum(patroni_postgres_streaming)", "legendFormat": "Streaming"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "green", "value": 1}]}}}},
    {"id": 18, "title": "WAL Position (Primary)", "type": "stat", "gridPos": {"h": 3, "w": 6, "x": 12, "y": 21}, "targets": [{"expr": "max(patroni_xlog_location{name=~\".*patroni.*\"})", "legendFormat": "WAL Position"}], "fieldConfig": {"defaults": {"unit": "bytes"}}},
    {"id": 19, "title": "Replication Lag Over Time", "type": "timeseries", "gridPos": {"h": 5, "w": 6, "x": 18, "y": 21}, "targets": [{"expr": "pg_replication_lag_seconds", "legendFormat": "{{instance}}"}], "fieldConfig": {"defaults": {"unit": "s", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 20}}}},
    {"id": 20, "title": "PgBouncer", "type": "row", "gridPos": {"h": 1, "w": 24, "x": 0, "y": 26}, "collapsed": false},
    {"id": 21, "title": "PgBouncer Status", "description": "PgBouncer exporter connectivity", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 0, "y": 27}, "targets": [{"expr": "sum(pgbouncer_up)", "legendFormat": "Up"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 1}, {"color": "green", "value": 2}]}, "mappings": [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "1 Node", "color": "yellow"}, "2": {"text": "2 Nodes", "color": "green"}}}]}}},
    {"id": 22, "title": "Active Client Connections", "description": "Clients actively executing queries", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 4, "y": 27}, "targets": [{"expr": "sum(pgbouncer_pools_client_active_connections)", "legendFormat": "Active"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 50}, {"color": "red", "value": 90}]}}}},
    {"id": 23, "title": "Waiting Clients", "description": "Clients waiting for a server connection (should be 0)", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 8, "y": 27}, "targets": [{"expr": "sum(pgbouncer_pools_client_waiting_connections)", "legendFormat": "Waiting"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 5}, {"color": "red", "value": 10}]}}}},
    {"id": 24, "title": "Server Connections (Active)", "description": "Backend connections actively processing queries", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 12, "y": 27}, "targets": [{"expr": "sum(pgbouncer_pools_server_active_connections)", "legendFormat": "Active"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 15}, {"color": "red", "value": 20}]}}}},
    {"id": 25, "title": "Server Connections (Idle)", "description": "Backend connections available in pool", "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 16, "y": 27}, "targets": [{"expr": "sum(pgbouncer_pools_server_idle_connections)", "legendFormat": "Idle"}], "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}}},
    {"id": 26, "title": "Pool Utilization", "description": "Percentage of pool being used", "type": "gauge", "gridPos": {"h": 4, "w": 4, "x": 20, "y": 27}, "targets": [{"expr": "sum(pgbouncer_pools_server_active_connections) / (sum(pgbouncer_pools_server_active_connections) + sum(pgbouncer_pools_server_idle_connections)) * 100", "legendFormat": "Usage"}], "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}}}},
    {"id": 27, "title": "PgBouncer Client Connections Over Time", "type": "timeseries", "gridPos": {"h": 6, "w": 12, "x": 0, "y": 31}, "targets": [{"expr": "pgbouncer_pools_client_active_connections", "legendFormat": "active - {{database}}"}, {"expr": "pgbouncer_pools_client_waiting_connections", "legendFormat": "waiting - {{database}}"}], "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 28, "title": "PgBouncer Server Connections Over Time", "type": "timeseries", "gridPos": {"h": 6, "w": 12, "x": 12, "y": 31}, "targets": [{"expr": "pgbouncer_pools_server_active_connections", "legendFormat": "active - {{database}}"}, {"expr": "pgbouncer_pools_server_idle_connections", "legendFormat": "idle - {{database}}"}], "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 29, "title": "Queries per Second", "description": "Query throughput through PgBouncer", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 0, "y": 37}, "targets": [{"expr": "rate(pgbouncer_stats_totals_queries_pooled_total[1m])", "legendFormat": "{{database}}"}], "fieldConfig": {"defaults": {"unit": "qps", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 30, "title": "Average Query Time", "description": "Average time spent on queries", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 8, "y": 37}, "targets": [{"expr": "rate(pgbouncer_stats_totals_queries_duration_seconds_total[5m]) / rate(pgbouncer_stats_totals_queries_pooled_total[5m])", "legendFormat": "{{database}}"}], "fieldConfig": {"defaults": {"unit": "s", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}},
    {"id": 31, "title": "Network Traffic", "description": "Bytes sent/received through PgBouncer", "type": "timeseries", "gridPos": {"h": 6, "w": 8, "x": 16, "y": 37}, "targets": [{"expr": "rate(pgbouncer_stats_totals_received_bytes_total[1m])", "legendFormat": "received - {{database}}"}, {"expr": "rate(pgbouncer_stats_totals_sent_bytes_total[1m])", "legendFormat": "sent - {{database}}"}], "fieldConfig": {"defaults": {"unit": "Bps", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10}}}}
  ]
}
DASHBOARD

chown grafana:grafana /var/lib/grafana/dashboards/postgresql.json

# -----------------------------------------------------------------------------
# Start Services
# -----------------------------------------------------------------------------

echo "=== Starting services ==="

systemctl daemon-reload
systemctl enable prometheus alertmanager grafana-server
systemctl start prometheus alertmanager grafana-server

# Wait for services
sleep 10

echo "=== Monitoring stack installation complete ==="
echo "Prometheus: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9090"
echo "Grafana: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000 (admin/admin)"
echo "Alertmanager: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9093"
