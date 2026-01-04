# PostgreSQL HA/DR on AWS

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql)](https://postgresql.org)
[![Patroni](https://img.shields.io/badge/Patroni-4.x-2C3E50)](https://patroni.readthedocs.io/)
[![etcd](https://img.shields.io/badge/etcd-3.5.17-419EDA?logo=etcd)](https://etcd.io/)
[![pgBackRest](https://img.shields.io/badge/pgBackRest-2.54+-1E8449)](https://pgbackrest.org/)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-623CE4?logo=terraform)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-EC2%20|%20NLB%20|%20S3-FF9900?logo=amazonaws)](https://aws.amazon.com)

**[English](#english)** | **[Português](#português)**

---

## English

Production-grade PostgreSQL cluster with **automatic failover**, **cross-region disaster recovery**, and **point-in-time recovery** on AWS.

### Architecture

```mermaid
graph TD
      classDef aws fill:#FF9900,stroke:#232F3E,stroke-width:2px,color:white
      classDef db fill:#336791,stroke:#333,stroke-width:2px,color:white
      classDef app fill:#6DB33F,stroke:#333,stroke-width:2px,color:white
      classDef monitor fill:#E6522C,stroke:#333,stroke-width:2px,color:white
      classDef storage fill:#3F8624,stroke:#333,stroke-width:2px,color:white
      classDef public fill:#fff,stroke:#E63946,stroke-width:3px,color:#333
      classDef internal fill:#f5f5f5,stroke:#333,stroke-width:1px,color:#333

      INTERNET(("Internet"))

      subgraph AWS["AWS Cloud"]
          subgraph PRIMARY["us-east-1"]

              BASTION["Bastion<br/>:22"]:::public
              API["API Server<br/>:8000 :8001"]:::public
              MON["Monitoring<br/>Grafana :3000<br/>Prometheus :9090<br/>Alertmanager :9093"]:::public

              NLB["NLB (internal)<br/>:6432 :5432 :5433"]:::internal

              subgraph N1["Patroni-1"]
                  direction TB
                  PGB1["PgBouncer"]:::db
                  PG1["PostgreSQL 17"]:::db
                  EXP1["Exporters"]:::monitor
              end

              subgraph N2["Patroni-2"]
                  direction TB
                  PGB2["PgBouncer"]:::db
                  PG2["PostgreSQL 17"]:::db
                  EXP2["Exporters"]:::monitor
              end

              ETCD1["etcd-1"]:::aws
              ETCD2["etcd-2"]:::aws
              ETCD3["etcd-3"]:::aws

              SSM["SSM"]:::aws
          end

          subgraph DR["us-west-2"]
              STANDBY["DR Standby"]:::db
          end

          S3[("S3 pgBackRest")]:::storage
      end

      %% Public access
      INTERNET --> BASTION
      INTERNET --> API
      INTERNET --> MON

      %% API to DB (internal)
      API --> NLB
      NLB --> PGB1 & PGB2
      PGB1 --> PG1
      PGB2 --> PG2

      %% Replication
      PG1 -.-> PG2

      %% Consensus
      PG1 & PG2 <--> ETCD1 & ETCD2 & ETCD3

      %% Backups
      PG1 --> S3
      STANDBY --> S3

      %% Secrets
      SSM -.-> N1 & N2

      %% Monitoring (Scrape Exporters)
      MON -.-> EXP1 & EXP2

      %% Admin (SSH)
      BASTION -.-> N1 & N2

      %% DR
      PG1 ==> STANDBY
```

### Key Features

| Feature | Implementation | Benefit |
|---------|----------------|---------|
| **High Availability** | Patroni + etcd | Automatic failover in ~15 seconds |
| **Disaster Recovery** | Cross-region standby | Region-level resilience |
| **Point-in-Time Recovery** | pgBackRest + S3 | Restore to any second |
| **Observability** | Prometheus + Grafana | Metrics, dashboards, alerts |
| **Infrastructure as Code** | Terraform | 100% reproducible |
| **Encryption at Rest** | EBS Encryption | Data protection compliance |
| **Connection Pooling** | PgBouncer | Efficient connection reuse |

### Recovery Objectives

| Metric | Target | How |
|--------|--------|-----|
| **RPO** | < 5 min | Continuous WAL archiving to S3 |
| **RTO** | < 30 min | Automated failover + documented runbooks |

### Quick Start

#### Prerequisites

- AWS CLI configured (`aws configure --profile postgresql-ha-profile`)
- Terraform >= 1.6
- EC2 key pair in target region

#### Deploy

```bash
# Clone
git clone https://github.com/yourusername/postgresql-ha-dr.git
cd postgresql-ha-dr/terraform

# Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Deploy primary region
terraform init && terraform apply

# (Optional) Deploy DR region
cd dr-region && terraform init && terraform apply
```

#### Connect

```bash
# Get connection endpoint
terraform output nlb_dns_name

# Connect to PostgreSQL (Direct)
psql -h <nlb-dns> -p 5432 -U postgres  # Read/Write (Primary)
psql -h <nlb-dns> -p 5433 -U postgres  # Read-Only (Replica)

# Connect via PgBouncer (Pooled - recommended for applications)
psql -h <nlb-dns> -p 6432 -U postgres  # Connection pooling
```

> **Tip:** Use port 6432 (PgBouncer) for applications to benefit from connection pooling and efficient resource usage.

### Project Structure

```
postgresql-ha-dr/
├── terraform/              # Infrastructure as Code
│   ├── *.tf                # Primary region resources
│   ├── scripts/            # EC2 user-data templates
│   └── dr-region/          # DR region (us-west-2)
├── api/                    # FastAPI (Python)
├── api-go/                 # Gin API (Go)
├── scripts/                # Operational scripts
│   ├── backup-full.sh
│   ├── restore-pitr.sh
│   └── verify-backup.sh
└── docs/                   # Documentation
    ├── dr-runbook.md       # Disaster recovery procedures
    ├── runbook-setup.md    # Complete setup guide
    └── monitoring.md       # Observability stack
```

### Operations

| Task | Command |
|------|---------|
| Check cluster health | `curl http://<patroni-ip>:8008/cluster \| jq` |
| Full backup | `./scripts/backup-full.sh` |
| Verify backups | `./scripts/verify-backup.sh` |
| Point-in-time restore | `./scripts/restore-pitr.sh "2025-01-15T14:30:00+00:00"` |
| DR failover | See [docs/dr-runbook.md](docs/dr-runbook.md) |

> **Note:** PITR timestamps use ISO 8601 format with timezone (e.g., `+00:00` for UTC).

### Cost Estimate

| Component | Monthly Cost |
|-----------|-------------|
| EC2 (8x t3.micro) | ~$50* |
| NLB | ~$20 |
| S3 (backups) | ~$5 |
| VPC Peering | ~$1 |
| **Total** | **~$76/mo** |

*Free Tier eligible for first 12 months (750 hrs/mo)*

### Tech Stack

| Layer | Technology |
|-------|------------|
| Database | PostgreSQL 17 |
| HA Orchestration | Patroni 4.0 |
| Consensus | etcd 3.5 |
| Backup | pgBackRest 2.54 |
| Metrics | Prometheus 2.54 |
| Dashboards | Grafana 11 |
| IaC | Terraform 1.6+ |

### Documentation

- [Complete Setup Guide](docs/runbook-setup.md)
- [DR Runbook](docs/dr-runbook.md)
- [Monitoring Stack](docs/monitoring.md)

### Acknowledgments

This project was developed with the assistance of [Claude Code](https://claude.ai/).

### License

This project is licensed under the MIT License.

---

## Português

Cluster PostgreSQL de produção com **failover automático**, **disaster recovery cross-region** e **point-in-time recovery** na AWS.

### Arquitetura

```mermaid
graph TD
      classDef aws fill:#FF9900,stroke:#232F3E,stroke-width:2px,color:white
      classDef db fill:#336791,stroke:#333,stroke-width:2px,color:white
      classDef app fill:#6DB33F,stroke:#333,stroke-width:2px,color:white
      classDef monitor fill:#E6522C,stroke:#333,stroke-width:2px,color:white
      classDef storage fill:#3F8624,stroke:#333,stroke-width:2px,color:white
      classDef public fill:#fff,stroke:#E63946,stroke-width:3px,color:#333
      classDef internal fill:#f5f5f5,stroke:#333,stroke-width:1px,color:#333

      INTERNET(("Internet"))

      subgraph AWS["AWS Cloud"]
          subgraph PRIMARY["us-east-1"]

              BASTION["Bastion<br/>:22"]:::public
              API["API Server<br/>:8000 :8001"]:::public
              MON["Monitoring<br/>Grafana :3000<br/>Prometheus :9090<br/>Alertmanager :9093"]:::public

              NLB["NLB (internal)<br/>:6432 :5432 :5433"]:::internal

              subgraph N1["Patroni-1"]
                  direction TB
                  PGB1["PgBouncer"]:::db
                  PG1["PostgreSQL 17"]:::db
                  EXP1["Exporters"]:::monitor
              end

              subgraph N2["Patroni-2"]
                  direction TB
                  PGB2["PgBouncer"]:::db
                  PG2["PostgreSQL 17"]:::db
                  EXP2["Exporters"]:::monitor
              end

              ETCD1["etcd-1"]:::aws
              ETCD2["etcd-2"]:::aws
              ETCD3["etcd-3"]:::aws

              SSM["SSM"]:::aws
          end

          subgraph DR["us-west-2"]
              STANDBY["DR Standby"]:::db
          end

          S3[("S3 pgBackRest")]:::storage
      end

      %% Public access
      INTERNET --> BASTION
      INTERNET --> API
      INTERNET --> MON

      %% API to DB (internal)
      API --> NLB
      NLB --> PGB1 & PGB2
      PGB1 --> PG1
      PGB2 --> PG2

      %% Replication
      PG1 -.-> PG2

      %% Consensus
      PG1 & PG2 <--> ETCD1 & ETCD2 & ETCD3

      %% Backups
      PG1 --> S3
      STANDBY --> S3

      %% Secrets
      SSM -.-> N1 & N2

      %% Monitoring (Scrape Exporters)
      MON -.-> EXP1 & EXP2

      %% Admin (SSH)
      BASTION -.-> N1 & N2

      %% DR
      PG1 ==> STANDBY
```

### Funcionalidades

| Funcionalidade | Implementação | Benefício |
|----------------|---------------|-----------|
| **Alta Disponibilidade** | Patroni + etcd | Failover automático em ~15 segundos |
| **Disaster Recovery** | Standby cross-region | Resiliência a nível de região |
| **Point-in-Time Recovery** | pgBackRest + S3 | Restauração para qualquer segundo |
| **Observabilidade** | Prometheus + Grafana | Métricas, dashboards, alertas |
| **Infraestrutura como Código** | Terraform | 100% reproduzível |
| **Criptografia em Repouso** | EBS Encryption | Conformidade com proteção de dados |
| **Connection Pooling** | PgBouncer | Reutilização eficiente de conexões |

### Objetivos de Recuperação

| Métrica | Alvo | Como |
|---------|------|------|
| **RPO** | < 5 min | Arquivamento contínuo de WAL para S3 |
| **RTO** | < 30 min | Failover automatizado + runbooks documentados |

### Início Rápido

#### Pré-requisitos

- AWS CLI configurado (`aws configure --profile postgresql-ha-profile`)
- Terraform >= 1.6
- Key pair EC2 na região alvo

#### Deploy

```bash
# Clonar
git clone https://github.com/yourusername/postgresql-ha-dr.git
cd postgresql-ha-dr/terraform

# Configurar
cp terraform.tfvars.example terraform.tfvars
# Edite terraform.tfvars com seus valores

# Deploy da região primária
terraform init && terraform apply

# (Opcional) Deploy da região DR
cd dr-region && terraform init && terraform apply
```

#### Conectar

```bash
# Obter endpoint de conexão
terraform output nlb_dns_name

# Conectar ao PostgreSQL (Direto)
psql -h <nlb-dns> -p 5432 -U postgres  # Leitura/Escrita (Primário)
psql -h <nlb-dns> -p 5433 -U postgres  # Somente Leitura (Réplica)

# Conectar via PgBouncer (Pooled - recomendado para aplicações)
psql -h <nlb-dns> -p 6432 -U postgres  # Connection pooling
```

> **Dica:** Use a porta 6432 (PgBouncer) para aplicações para aproveitar connection pooling e uso eficiente de recursos.

### Estrutura do Projeto

```
postgresql-ha-dr/
├── terraform/              # Infraestrutura como Código
│   ├── *.tf                # Recursos da região primária
│   ├── scripts/            # Templates user-data EC2
│   └── dr-region/          # Região DR (us-west-2)
├── api/                    # FastAPI (Python)
├── api-go/                 # Gin API (Go)
├── scripts/                # Scripts operacionais
│   ├── backup-full.sh
│   ├── restore-pitr.sh
│   └── verify-backup.sh
└── docs/                   # Documentação
    ├── dr-runbook.md       # Procedimentos de DR
    ├── runbook-setup.md    # Guia completo de setup
    └── monitoring.md       # Stack de observabilidade
```

### Operações

| Tarefa | Comando |
|--------|---------|
| Verificar saúde do cluster | `curl http://<patroni-ip>:8008/cluster \| jq` |
| Backup completo | `./scripts/backup-full.sh` |
| Verificar backups | `./scripts/verify-backup.sh` |
| Restauração point-in-time | `./scripts/restore-pitr.sh "2025-01-15T14:30:00+00:00"` |
| Failover DR | Veja [docs/dr-runbook.md](docs/dr-runbook.md) |

> **Nota:** Timestamps PITR usam formato ISO 8601 com timezone (ex: `+00:00` para UTC).

### Estimativa de Custos

| Componente | Custo Mensal |
|------------|--------------|
| EC2 (8x t3.micro) | ~$50* |
| NLB | ~$20 |
| S3 (backups) | ~$5 |
| VPC Peering | ~$1 |
| **Total** | **~$76/mês** |

*Elegível ao Free Tier nos primeiros 12 meses (750 hrs/mês)*

### Stack Tecnológico

| Camada | Tecnologia |
|--------|------------|
| Banco de Dados | PostgreSQL 17 |
| Orquestração HA | Patroni 4.0 |
| Consenso | etcd 3.5 |
| Backup | pgBackRest 2.54 |
| Métricas | Prometheus 2.54 |
| Dashboards | Grafana 11 |
| IaC | Terraform 1.6+ |

### Documentação

- [Guia Completo de Setup](docs/runbook-setup.md)
- [Runbook de DR](docs/dr-runbook.md)
- [Stack de Monitoramento](docs/monitoring.md)

### Agradecimentos

Este projeto foi desenvolvido com a assistência do [Claude Code](https://claude.ai/).

### Licença

Este projeto está licenciado sob a Licença MIT.
