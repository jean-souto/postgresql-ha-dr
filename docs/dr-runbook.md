# Disaster Recovery Runbook

**[English](#english)** | **[Português](#português)**

---

## English

### PostgreSQL HA/DR - Procedures and Escalation

---

### Table of Contents

1. [Overview](#overview)
2. [Architecture Summary](#architecture-summary)
3. [Recovery Objectives](#recovery-objectives)
4. [Daily Operations](#daily-operations)
5. [Incident Response](#incident-response)
6. [Recovery Procedures](#recovery-procedures)
7. [Post-Recovery Validation](#post-recovery-validation)
8. [Troubleshooting](#troubleshooting)

---

### Overview

This runbook provides step-by-step procedures for disaster recovery operations on the PostgreSQL HA cluster managed by Patroni with pgBackRest backups to S3.

#### Key Components

| Component | Purpose |
|-----------|---------|
| **Patroni** | HA orchestration, automatic failover |
| **etcd** | Distributed configuration store |
| **pgBackRest** | Backup and WAL archiving to S3 |
| **NLB** | Load balancing for PostgreSQL connections |

#### Critical Information

```
AWS Profile:     postgresql-ha-profile
Primary Region:  us-east-1
DR Region:       us-west-2
Stanza Name:     pgha-dev-postgres
```

---

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                      us-east-1 (Primary)                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Patroni-1  │  │  Patroni-2  │  │    etcd     │         │
│  │  (Primary)  │  │  (Replica)  │  │  (3 nodes)  │         │
│  └──────┬──────┘  └──────┬──────┘  └─────────────┘         │
│         └────────────────┴──────────────┘                   │
│                          │                                  │
│              ┌───────────┴───────────┐                     │
│              │    S3 (pgBackRest)    │                     │
│              └───────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
                           │
                    VPC Peering
                           │
┌─────────────────────────────────────────────────────────────┐
│                      us-west-2 (DR)                          │
│              ┌───────────────────────┐                      │
│              │    Standby Cluster    │                      │
│              │  Streaming Replication│                      │
│              └───────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

---

### Recovery Objectives

| Metric | Target | Current |
|--------|--------|---------|
| **RPO** (Recovery Point Objective) | 5 minutes | ~1 minute |
| **RTO** (Recovery Time Objective) | 30 minutes | 15-20 minutes |

---

### Daily Operations

#### 1. Verify Backup Status

```bash
./scripts/verify-backup.sh --full
```

Expected output:
- ✅ pgBackRest installation OK
- ✅ Stanza status OK
- ✅ At least 1 full backup exists
- ✅ WAL archiving active

#### 2. Check Cluster Health

```bash
curl -s http://<any-node-ip>:8008/cluster | jq .
```

#### 3. Verify Replication Lag

```bash
sudo -u postgres psql -c "SELECT client_addr, state,
  pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
  FROM pg_stat_replication;"
```

Acceptable lag: < 1MB under normal operations.

---

### Incident Response

#### Incident Classification

| Severity | Description | Response Time |
|----------|-------------|---------------|
| **P1 - Critical** | Complete cluster down | Immediate |
| **P2 - High** | Primary down, failover needed | < 15 min |
| **P3 - Medium** | Replica down, degraded HA | < 1 hour |
| **P4 - Low** | Performance degradation | < 4 hours |

---

### Recovery Procedures

#### Procedure 1: Automatic Failover (Patroni Managed)

Patroni handles most failover scenarios automatically.

```bash
# Monitor Patroni logs
journalctl -u patroni -f

# Verify new primary elected
curl -s http://<any-node>:8008/cluster | jq '.members[] | select(.role=="leader")'
```

#### Procedure 2: Manual Failover

```bash
patronictl -c /etc/patroni/patroni.yml switchover pgha-dev-postgres \
  --leader <current-primary-name> \
  --candidate <target-replica-name> \
  --force
```

#### Procedure 3: Point-in-Time Recovery (PITR)

**⚠️ WARNING: This is a DESTRUCTIVE operation!**

```bash
TARGET_TIME="2025-01-15 14:30:00"
./scripts/restore-pitr.sh "$TARGET_TIME"
```

#### Procedure 4: Cross-Region DR Activation

Use when entire primary region (us-east-1) is unavailable.

```bash
# 1. Connect to DR standby via SSM
aws ssm start-session --target <dr-instance-id> --region us-west-2

# 2. Check replication status
/usr/local/bin/check-replication.sh

# 3. Promote to primary
/usr/local/bin/promote-to-primary.sh

# 4. Verify promotion
su - postgres -c "psql -c 'SELECT pg_is_in_recovery()'"
# Should return 'f' (false)
```

---

### Post-Recovery Validation

```bash
# 1. Database Integrity
sudo -u postgres psql -c "SELECT 1;"

# 2. Replication Status
curl -s http://<primary>:8008/cluster | jq .

# 3. Backup Verification
./scripts/verify-backup.sh --full

# 4. Create new backup
./scripts/backup-full.sh
```

---

### Troubleshooting

#### Issue: Patroni won't start

```bash
journalctl -u patroni -n 100 --no-pager

# Fix permissions
sudo chown -R postgres:postgres /var/lib/pgsql/17/data
sudo chmod 700 /var/lib/pgsql/17/data
```

#### Issue: Backup fails

```bash
tail -100 /var/log/pgbackrest/pgha-dev-postgres-backup.log
```

#### Issue: High replication lag

```bash
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE state != 'idle';"
```

---

### Quick Reference Card

```
┌─────────────────────────────────────────────────────────────┐
│                    QUICK COMMANDS                           │
├─────────────────────────────────────────────────────────────┤
│ Check cluster:     curl -s http://<ip>:8008/cluster | jq .  │
│ Trigger switchover: patronictl switchover <cluster>         │
│ Run backup:        ./scripts/backup-full.sh                 │
│ Verify backup:     ./scripts/verify-backup.sh               │
│ PITR restore:      ./scripts/restore-pitr.sh "<timestamp>"  │
└─────────────────────────────────────────────────────────────┘
```

---

---

## Português

### PostgreSQL HA/DR - Procedimentos e Escalação

---

### Índice

1. [Visão Geral](#visão-geral)
2. [Resumo da Arquitetura](#resumo-da-arquitetura)
3. [Objetivos de Recuperação](#objetivos-de-recuperação)
4. [Operações Diárias](#operações-diárias)
5. [Resposta a Incidentes](#resposta-a-incidentes)
6. [Procedimentos de Recuperação](#procedimentos-de-recuperação)
7. [Validação Pós-Recuperação](#validação-pós-recuperação)
8. [Solução de Problemas](#solução-de-problemas)

---

### Visão Geral

Este runbook fornece procedimentos passo a passo para operações de disaster recovery no cluster PostgreSQL HA gerenciado pelo Patroni com backups pgBackRest para S3.

#### Componentes Principais

| Componente | Propósito |
|------------|-----------|
| **Patroni** | Orquestração HA, failover automático |
| **etcd** | Armazenamento de configuração distribuído |
| **pgBackRest** | Backup e arquivamento WAL para S3 |
| **NLB** | Balanceamento de carga para conexões PostgreSQL |

#### Informações Críticas

```
Perfil AWS:       postgresql-ha-profile
Região Primária:  us-east-1
Região DR:        us-west-2
Nome do Stanza:   pgha-dev-postgres
```

---

### Resumo da Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                      us-east-1 (Primária)                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Patroni-1  │  │  Patroni-2  │  │    etcd     │         │
│  │  (Primário) │  │  (Réplica)  │  │  (3 nós)    │         │
│  └──────┬──────┘  └──────┬──────┘  └─────────────┘         │
│         └────────────────┴──────────────┘                   │
│                          │                                  │
│              ┌───────────┴───────────┐                     │
│              │    S3 (pgBackRest)    │                     │
│              └───────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
                           │
                    VPC Peering
                           │
┌─────────────────────────────────────────────────────────────┐
│                      us-west-2 (DR)                          │
│              ┌───────────────────────┐                      │
│              │   Cluster Standby     │                      │
│              │  Replicação Streaming │                      │
│              └───────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

---

### Objetivos de Recuperação

| Métrica | Alvo | Atual |
|---------|------|-------|
| **RPO** (Objetivo de Ponto de Recuperação) | 5 minutos | ~1 minuto |
| **RTO** (Objetivo de Tempo de Recuperação) | 30 minutos | 15-20 minutos |

---

### Operações Diárias

#### 1. Verificar Status do Backup

```bash
./scripts/verify-backup.sh --full
```

Saída esperada:
- ✅ Instalação pgBackRest OK
- ✅ Status do stanza OK
- ✅ Pelo menos 1 backup completo existe
- ✅ Arquivamento WAL ativo

#### 2. Verificar Saúde do Cluster

```bash
curl -s http://<any-node-ip>:8008/cluster | jq .
```

#### 3. Verificar Lag de Replicação

```bash
sudo -u postgres psql -c "SELECT client_addr, state,
  pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
  FROM pg_stat_replication;"
```

Lag aceitável: < 1MB em operações normais.

---

### Resposta a Incidentes

#### Classificação de Incidentes

| Severidade | Descrição | Tempo de Resposta |
|------------|-----------|-------------------|
| **P1 - Crítico** | Cluster completamente fora | Imediato |
| **P2 - Alto** | Primário fora, failover necessário | < 15 min |
| **P3 - Médio** | Réplica fora, HA degradado | < 1 hora |
| **P4 - Baixo** | Degradação de performance | < 4 horas |

---

### Procedimentos de Recuperação

#### Procedimento 1: Failover Automático (Gerenciado pelo Patroni)

O Patroni lida com a maioria dos cenários de failover automaticamente.

```bash
# Monitorar logs do Patroni
journalctl -u patroni -f

# Verificar novo primário eleito
curl -s http://<any-node>:8008/cluster | jq '.members[] | select(.role=="leader")'
```

#### Procedimento 2: Failover Manual

```bash
patronictl -c /etc/patroni/patroni.yml switchover pgha-dev-postgres \
  --leader <nome-primario-atual> \
  --candidate <nome-replica-alvo> \
  --force
```

#### Procedimento 3: Point-in-Time Recovery (PITR)

**⚠️ ATENÇÃO: Esta é uma operação DESTRUTIVA!**

```bash
TARGET_TIME="2025-01-15 14:30:00"
./scripts/restore-pitr.sh "$TARGET_TIME"
```

#### Procedimento 4: Ativação de DR Cross-Region

Use quando toda a região primária (us-east-1) estiver indisponível.

```bash
# 1. Conectar ao standby DR via SSM
aws ssm start-session --target <dr-instance-id> --region us-west-2

# 2. Verificar status da replicação
/usr/local/bin/check-replication.sh

# 3. Promover para primário
/usr/local/bin/promote-to-primary.sh

# 4. Verificar promoção
su - postgres -c "psql -c 'SELECT pg_is_in_recovery()'"
# Deve retornar 'f' (false)
```

---

### Validação Pós-Recuperação

```bash
# 1. Integridade do Banco de Dados
sudo -u postgres psql -c "SELECT 1;"

# 2. Status da Replicação
curl -s http://<primary>:8008/cluster | jq .

# 3. Verificação de Backup
./scripts/verify-backup.sh --full

# 4. Criar novo backup
./scripts/backup-full.sh
```

---

### Solução de Problemas

#### Problema: Patroni não inicia

```bash
journalctl -u patroni -n 100 --no-pager

# Corrigir permissões
sudo chown -R postgres:postgres /var/lib/pgsql/17/data
sudo chmod 700 /var/lib/pgsql/17/data
```

#### Problema: Backup falha

```bash
tail -100 /var/log/pgbackrest/pgha-dev-postgres-backup.log
```

#### Problema: Lag de replicação alto

```bash
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE state != 'idle';"
```

---

### Cartão de Referência Rápida

```
┌─────────────────────────────────────────────────────────────┐
│                   COMANDOS RÁPIDOS                          │
├─────────────────────────────────────────────────────────────┤
│ Verificar cluster:  curl -s http://<ip>:8008/cluster | jq . │
│ Executar switchover: patronictl switchover <cluster>        │
│ Executar backup:    ./scripts/backup-full.sh                │
│ Verificar backup:   ./scripts/verify-backup.sh              │
│ Restauração PITR:   ./scripts/restore-pitr.sh "<timestamp>" │
└─────────────────────────────────────────────────────────────┘
```
