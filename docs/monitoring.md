# Monitoring Stack - PostgreSQL HA/DR

**[English](#english)** | **[Português](#português)**

---

## English

### Overview

The monitoring stack consists of:

| Component | Port | Function |
|-----------|------|----------|
| **Prometheus** | 9090 | Metrics collection and storage |
| **Grafana** | 3000 | Visualization and dashboards |
| **Alertmanager** | 9093 | Alert management and routing |

### Access URLs

```
Prometheus:     http://<monitoring-public-ip>:9090
Grafana:        http://<monitoring-public-ip>:3000  (admin/admin)
Alertmanager:   http://<monitoring-public-ip>:9093
```

To get the current IP:
```bash
aws ec2 describe-instances \
  --profile postgresql-ha-profile \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=pgha-dev-monitoring" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

### Collection Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Monitoring Instance                          │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐             │
│  │ Prometheus  │  │   Grafana   │  │ Alertmanager │             │
│  │   :9090     │  │    :3000    │  │    :9093     │             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘             │
└─────────┼────────────────┼─────────────────┼─────────────────────┘
          │                │                 │
          │ scrape         │ query           │ send alerts
          ▼                ▼                 ▼
┌─────────────────┐  ┌─────────────┐  ┌─────────────┐
│  Patroni Nodes  │  │ Prometheus  │  │  SNS Topic  │
│  :8008 (API)    │  │   (self)    │  │   (AWS)     │
│  :9100 (node)   │  │             │  │             │
│  :9187 (pg)     │  │             │  │             │
└─────────────────┘  └─────────────┘  └─────────────┘
         │
         ▼
┌─────────────────┐
│   etcd Nodes    │
│   :2379         │
└─────────────────┘
```

---

### Installed Exporters

#### Node Exporter (port 9100)
Operating system metrics:
- CPU, memory, disk, network
- Load average, processes
- Filesystem usage

#### Postgres Exporter (port 9187)
PostgreSQL metrics:
- Active connections
- Transactions (commit/rollback)
- Cache hit ratio
- Replication lag
- Database size
- Lock statistics

#### Patroni API (port 8008)
Patroni cluster metrics:
- Cluster state (primary/replica)
- Timeline and LSN positions
- Streaming replication status

#### PgBouncer Exporter (port 9127)
PgBouncer connection pooling metrics:
- Active/waiting client connections
- Active/idle server connections
- Query counts and duration
- Pool utilization

---

### Important Metrics

#### Cluster Health

| Metric | Description | Expected Value |
|--------|-------------|----------------|
| `patroni_primary` | Node is primary (1) or not (0) | Exactly 1 node with value 1 |
| `patroni_replica` | Node is replica (1) or not (0) | N-1 nodes with value 1 |
| `patroni_postgres_running` | PostgreSQL is running | 1 on all nodes |
| `pg_up` | Exporter can connect to PG | 1 on all nodes |

#### Replication

| Metric | Description | Threshold |
|--------|-------------|-----------|
| `pg_replication_lag` | Replication lag in seconds | < 60s (warning) |
| `patroni_xlog_location` | WAL position | Compare between nodes |

#### Performance

| Metric | Description | Threshold |
|--------|-------------|-----------|
| `pg_stat_activity_count` | Active connections | < 80% of max_connections |
| `pg_stat_database_xact_commit` | Transactions/second | App baseline |
| Cache hit ratio | blks_hit / (blks_hit + blks_read) | > 95% |

#### Connection Pooling (PgBouncer)

| Metric | Description | Threshold |
|--------|-------------|-----------|
| `pgbouncer_pools_client_active_connections` | Active client connections | Monitor for saturation |
| `pgbouncer_pools_server_active_connections` | Active server connections | < default_pool_size |
| `pgbouncer_pools_client_waiting_connections` | Waiting clients | 0 ideal, > 10 warning |
| `pgbouncer_pools_server_idle_connections` | Idle server connections | Expected when low traffic |

---

### Useful Prometheus Queries

#### Check Cluster Status
```promql
# Number of primaries (should be 1)
sum(patroni_primary)

# Number of replicas (should be N-1)
sum(patroni_replica)

# All PostgreSQL nodes running
sum(patroni_postgres_running)
```

#### Performance
```promql
# Active connections as % of maximum
pg_stat_activity_count / pg_settings_max_connections * 100

# Transactions per second
rate(pg_stat_database_xact_commit{datname="postgres"}[5m])
```

#### Infrastructure
```promql
# CPU usage %
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage %
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

---

### Configured Alerts

#### Critical (Immediate Action)

| Alert | Condition | Description |
|-------|-----------|-------------|
| **PostgreSQLDown** | `pg_up == 0` for 1m | PostgreSQL not responding |
| **PatroniNoPrimary** | `sum(patroni_primary) == 0` for 1m | No node is primary (cluster down) |
| **PatroniMultiplePrimaries** | `sum(patroni_primary) > 1` for 1m | Split-brain detected |

#### Warning (Investigate)

| Alert | Condition | Description |
|-------|-----------|-------------|
| **PatroniReplicaDown** | `sum(patroni_replica) < 1` for 5m | Less than 1 replica available |
| **PostgreSQLHighConnections** | Connections > 80% max for 5m | Too many connections |
| **PostgreSQLReplicationLag** | Lag > 60s for 5m | Replica too far behind |
| **HighCPUUsage** | CPU > 80% for 5m | High CPU usage |
| **DiskSpaceLow** | Disk > 80% used for 5m | Low disk space |

---

### Grafana Dashboards

#### PostgreSQL Overview (pre-installed)

Dashboard UID: `postgresql-overview`

**Direct URL:** `http://<monitoring-ip>:3000/d/postgresql-overview/postgresql-overview`

**Panels:**
- Database Size
- Active Connections
- Transactions/sec (commits vs rollbacks)
- Cache Hit Ratio (gauge)
- Replication Lag (graph)
- PgBouncer Active Clients
- PgBouncer Waiting Clients
- PgBouncer Server Connections
- PgBouncer Query Time (avg)

#### Automatic Dashboard Provisioning

Dashboards are automatically provisioned via Grafana's file-based provisioning:

```
/etc/grafana/provisioning/dashboards/default.yml  (config)
/var/lib/grafana/dashboards/postgresql.json       (dashboard JSON)
```

The dashboard JSON is created during instance bootstrap (user-data script).

**To add custom dashboards automatically:**

1. Add JSON file to `/var/lib/grafana/dashboards/`
2. Reload provisioning:
   ```bash
   curl -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/dashboards/reload
   ```

Or modify `terraform/scripts/user-data-monitoring.sh.tpl` to include additional dashboards.

#### How to Access
1. Open Grafana: `http://<monitoring-ip>:3000`
2. Login: `admin` / `admin` (change on first login)
3. Go to Dashboards → Browse
4. Click on "PostgreSQL Overview"

#### Import Additional Dashboards

Recommended dashboards from Grafana.com:

| ID | Name | Description |
|----|------|-------------|
| 9628 | PostgreSQL Database | Detailed PG metrics |
| 1860 | Node Exporter Full | Complete OS metrics |
| 3662 | Prometheus Stats | Prometheus self-monitoring |

---

### Quick Commands

```bash
# Status of all targets
curl -s http://<monitoring-ip>:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health}'

# Active alerts
curl -s http://<monitoring-ip>:9090/api/v1/alerts | jq '.data.alerts[]'

# Check if cluster is healthy
curl -s "http://<monitoring-ip>:9090/api/v1/query?query=sum(patroni_primary)" | jq '.data.result[0].value[1]'
# Should return "1"
```

---

---

## Português

### Visão Geral

O stack de monitoramento consiste em:

| Componente | Porta | Função |
|------------|-------|--------|
| **Prometheus** | 9090 | Coleta e armazenamento de métricas |
| **Grafana** | 3000 | Visualização e dashboards |
| **Alertmanager** | 9093 | Gerenciamento e roteamento de alertas |

### URLs de Acesso

```
Prometheus:     http://<monitoring-public-ip>:9090
Grafana:        http://<monitoring-public-ip>:3000  (admin/admin)
Alertmanager:   http://<monitoring-public-ip>:9093
```

Para obter o IP atual:
```bash
aws ec2 describe-instances \
  --profile postgresql-ha-profile \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=pgha-dev-monitoring" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

### Arquitetura de Coleta

```
┌─────────────────────────────────────────────────────────────────┐
│                     Monitoring Instance                          │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐             │
│  │ Prometheus  │  │   Grafana   │  │ Alertmanager │             │
│  │   :9090     │  │    :3000    │  │    :9093     │             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘             │
└─────────┼────────────────┼─────────────────┼─────────────────────┘
          │                │                 │
          │ scrape         │ query           │ send alerts
          ▼                ▼                 ▼
┌─────────────────┐  ┌─────────────┐  ┌─────────────┐
│  Patroni Nodes  │  │ Prometheus  │  │  SNS Topic  │
│  :8008 (API)    │  │   (self)    │  │   (AWS)     │
│  :9100 (node)   │  │             │  │             │
│  :9187 (pg)     │  │             │  │             │
└─────────────────┘  └─────────────┘  └─────────────┘
         │
         ▼
┌─────────────────┐
│   etcd Nodes    │
│   :2379         │
└─────────────────┘
```

---

### Exporters Instalados

#### Node Exporter (porta 9100)
Métricas de sistema operacional:
- CPU, memória, disco, rede
- Load average, processos
- Filesystem usage

#### Postgres Exporter (porta 9187)
Métricas do PostgreSQL:
- Conexões ativas
- Transações (commit/rollback)
- Cache hit ratio
- Replication lag
- Database size
- Lock statistics

#### Patroni API (porta 8008)
Métricas do cluster Patroni:
- Estado do cluster (primary/replica)
- Timeline e LSN positions
- Streaming replication status

---

### Métricas Importantes

#### Cluster Health

| Métrica | Descrição | Valor Esperado |
|---------|-----------|----------------|
| `patroni_primary` | Nó é primary (1) ou não (0) | Exatamente 1 nó com valor 1 |
| `patroni_replica` | Nó é replica (1) ou não (0) | N-1 nós com valor 1 |
| `patroni_postgres_running` | PostgreSQL está rodando | 1 em todos os nós |
| `pg_up` | Exporter consegue conectar ao PG | 1 em todos os nós |

#### Replicação

| Métrica | Descrição | Threshold |
|---------|-----------|-----------|
| `pg_replication_lag` | Lag de replicação em segundos | < 60s (warning) |
| `patroni_xlog_location` | Posição do WAL | Comparar entre nós |

#### Performance

| Métrica | Descrição | Threshold |
|---------|-----------|-----------|
| `pg_stat_activity_count` | Conexões ativas | < 80% de max_connections |
| `pg_stat_database_xact_commit` | Transações/segundo | Baseline do app |
| Cache hit ratio | blks_hit / (blks_hit + blks_read) | > 95% |

#### Connection Pooling (PgBouncer)

| Métrica | Descrição | Threshold |
|---------|-----------|-----------|
| `pgbouncer_pools_client_active_connections` | Conexões de clientes ativas | Monitorar saturação |
| `pgbouncer_pools_server_active_connections` | Conexões de servidor ativas | < default_pool_size |
| `pgbouncer_pools_client_waiting_connections` | Clientes aguardando | 0 ideal, > 10 warning |
| `pgbouncer_pools_server_idle_connections` | Conexões de servidor ociosas | Esperado em baixo tráfego |

---

### Queries Prometheus Úteis

#### Verificar Cluster Status
```promql
# Número de primaries (deve ser 1)
sum(patroni_primary)

# Número de replicas (deve ser N-1)
sum(patroni_replica)

# Todos os nós PostgreSQL rodando
sum(patroni_postgres_running)
```

#### Performance
```promql
# Conexões ativas como % do máximo
pg_stat_activity_count / pg_settings_max_connections * 100

# Transações por segundo
rate(pg_stat_database_xact_commit{datname="postgres"}[5m])
```

#### Infraestrutura
```promql
# CPU usage %
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage %
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

---

### Alertas Configurados

#### Critical (Ação Imediata)

| Alerta | Condição | Descrição |
|--------|----------|-----------|
| **PostgreSQLDown** | `pg_up == 0` por 1m | PostgreSQL não está respondendo |
| **PatroniNoPrimary** | `sum(patroni_primary) == 0` por 1m | Nenhum nó é primary (cluster down) |
| **PatroniMultiplePrimaries** | `sum(patroni_primary) > 1` por 1m | Split-brain detectado |

#### Warning (Investigar)

| Alerta | Condição | Descrição |
|--------|----------|-----------|
| **PatroniReplicaDown** | `sum(patroni_replica) < 1` por 5m | Menos de 1 replica disponível |
| **PostgreSQLHighConnections** | Conexões > 80% max por 5m | Muitas conexões |
| **PostgreSQLReplicationLag** | Lag > 60s por 5m | Replica muito atrasada |
| **HighCPUUsage** | CPU > 80% por 5m | Alto uso de CPU |
| **DiskSpaceLow** | Disco > 80% usado por 5m | Pouco espaço em disco |

---

### Grafana Dashboards

#### PostgreSQL Overview (pré-instalado)

Dashboard UID: `postgresql-overview`

**URL Direta:** `http://<monitoring-ip>:3000/d/postgresql-overview/postgresql-overview`

**Painéis:**
- Database Size
- Active Connections
- Transactions/sec (commits vs rollbacks)
- Cache Hit Ratio (gauge)
- Replication Lag (graph)
- PgBouncer Active Clients
- PgBouncer Waiting Clients
- PgBouncer Server Connections
- PgBouncer Query Time (avg)

#### Provisionamento Automático de Dashboards

Os dashboards são provisionados automaticamente via file-based provisioning do Grafana:

```
/etc/grafana/provisioning/dashboards/default.yml  (config)
/var/lib/grafana/dashboards/postgresql.json       (dashboard JSON)
```

O JSON do dashboard é criado durante o bootstrap da instância (script user-data).

**Para adicionar dashboards customizados automaticamente:**

1. Adicione arquivo JSON em `/var/lib/grafana/dashboards/`
2. Recarregue o provisionamento:
   ```bash
   curl -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/dashboards/reload
   ```

Ou modifique `terraform/scripts/user-data-monitoring.sh.tpl` para incluir dashboards adicionais.

#### Como Acessar
1. Abra Grafana: `http://<monitoring-ip>:3000`
2. Login: `admin` / `admin` (mude na primeira vez)
3. Vá em Dashboards → Browse
4. Clique em "PostgreSQL Overview"

#### Importar Dashboards Adicionais

Dashboards recomendados do Grafana.com:

| ID | Nome | Descrição |
|----|------|-----------|
| 9628 | PostgreSQL Database | Métricas detalhadas do PG |
| 1860 | Node Exporter Full | Sistema operacional completo |
| 3662 | Prometheus Stats | Monitoramento do próprio Prometheus |

---

### Comandos Rápidos

```bash
# Status de todos os targets
curl -s http://<monitoring-ip>:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health}'

# Alertas ativos
curl -s http://<monitoring-ip>:9090/api/v1/alerts | jq '.data.alerts[]'

# Verificar se cluster está saudável
curl -s "http://<monitoring-ip>:9090/api/v1/query?query=sum(patroni_primary)" | jq '.data.result[0].value[1]'
# Deve retornar "1"
```

---

### Referências

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [postgres_exporter Metrics](https://github.com/prometheus-community/postgres_exporter)
- [node_exporter Metrics](https://github.com/prometheus/node_exporter)
