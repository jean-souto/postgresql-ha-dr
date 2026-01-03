# HA, DR and Multi-Region DR: Concepts and Complementarity

**[English](#english)** | **[Português](#português)**

---

## English

### Overview

This document explains the differences between High Availability (HA), Disaster Recovery (DR), and Multi-Region DR, and why these strategies are complementary rather than mutually exclusive.

---

### 1. High Availability (HA)

#### What is it?

HA is the ability of a system to continue operating even when individual components fail. The goal is to **minimize downtime** through local redundancy.

#### Characteristics

| Aspect | Description |
|--------|-------------|
| **Scope** | Same region/datacenter |
| **Goal** | Zero or minimal downtime |
| **Failover** | Automatic (seconds) |
| **RPO** | Zero (synchronous replication) |
| **RTO** | Seconds to minutes |

#### How it works in this project

```
┌─────────────────────────────────────────────────────────┐
│                    us-east-1 (HA Cluster)               │
├─────────────────────────────────────────────────────────┤
│   ┌──────────┐    ┌──────────┐    ┌──────────┐         │
│   │ Patroni  │    │ Patroni  │    │ Patroni  │         │
│   │ Primary  │◄──►│ Replica  │◄──►│ Replica  │         │
│   │  (AZ-a)  │    │  (AZ-b)  │    │  (AZ-c)  │         │
│   └──────────┘    └──────────┘    └──────────┘         │
│        │                │                │              │
│        └────────────────┼────────────────┘              │
│                         ▼                               │
│                 ┌──────────────┐                        │
│                 │  etcd (DCS)  │                        │
│                 │  3 nodes     │                        │
│                 └──────────────┘                        │
└─────────────────────────────────────────────────────────┘
```

**Protection against:**
- EC2 instance failure
- PostgreSQL process failure
- Individual Availability Zone failure

---

### 2. Disaster Recovery (DR)

#### What is it?

DR is the ability to recover a system after a disaster that affects the entire primary infrastructure. The goal is to **ensure business continuity** after catastrophic events.

#### Characteristics

| Aspect | Description |
|--------|-------------|
| **Scope** | Alternate region/datacenter |
| **Goal** | Recovery after total disaster |
| **Failover** | Manual or semi-automatic (minutes/hours) |
| **RPO** | Minutes (asynchronous replication) |
| **RTO** | Minutes to hours |

#### Types of DR

##### Local DR (same region, backup/restore)

```
┌──────────────────┐         ┌──────────────────┐
│   HA Cluster     │ ──────► │   S3 Bucket      │
│   (Primary)      │  backup │   (pgBackRest)   │
└──────────────────┘         └──────────────────┘
                                      │
                                      ▼ restore
                             ┌──────────────────┐
                             │   New Instance   │
                             │   (if needed)    │
                             └──────────────────┘
```

**Protection against:**
- Data corruption
- Human error (DELETE without WHERE)
- Storage failure

##### Multi-Region DR (different regions)

```
┌────────────────────────┐         ┌────────────────────────┐
│      us-east-1         │         │      us-west-2         │
│    (Primary Region)    │         │     (DR Region)        │
├────────────────────────┤         ├────────────────────────┤
│   ┌──────────────┐     │         │   ┌──────────────┐     │
│   │  HA Cluster  │     │ ──────► │   │   Standby    │     │
│   │  (3 nodes)   │     │ async   │   │   (1 node)   │     │
│   └──────────────┘     │ replica │   └──────────────┘     │
│          │             │         │          │             │
│          ▼             │         │          ▼             │
│   ┌──────────────┐     │         │   ┌──────────────┐     │
│   │  S3 Bucket   │─────┼────────►│   │  S3 Bucket   │     │
│   │  (backups)   │ rep │         │   │  (replica)   │     │
│   └──────────────┘     │         │   └──────────────┘     │
└────────────────────────┘         └────────────────────────┘
```

**Protection against:**
- Complete AWS region failure
- Regional natural disasters
- Regional AWS infrastructure issues

---

### 3. Why HA and DR are Complementary?

#### Different Types of Failure

| Failure Type | HA Solves? | DR Solves? |
|--------------|------------|------------|
| EC2 instance goes down | ✅ Yes | ❌ Overkill |
| PostgreSQL process crash | ✅ Yes | ❌ Overkill |
| AZ becomes unavailable | ✅ Yes | ❌ Overkill |
| Data corruption | ❌ No* | ✅ Yes (PITR) |
| Accidental DELETE | ❌ No* | ✅ Yes (PITR) |
| Entire region goes down | ❌ No | ✅ Yes |
| Ransomware/attack | ❌ No* | ✅ Yes (offline backup) |

*HA replicates corrupted data to all replicas instantly.

#### Analogy

```
HA = Spare tire in the car
     → Solves punctures, doesn't solve accidents

DR = Car insurance + spare car
     → Solves accidents, but too slow for punctures
```

---

### 4. This Project: HA + DR Combined

#### Complete Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HA LAYER                                        │
│                           (us-east-1)                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  Patroni Cluster: 3 nodes in 3 AZs                                      ││
│  │  • Automatic failover in seconds                                        ││
│  │  • Synchronous replication (RPO = 0)                                    ││
│  │  • Coordination via etcd (3 nodes)                                      ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                          LOCAL DR LAYER                                 ││
│  │  pgBackRest → S3 (same region)                                          ││
│  │  • Weekly full backup                                                   ││
│  │  • Daily incremental backup                                             ││
│  │  • Continuous WAL archiving (RPO = 5 min)                               ││
│  │  • PITR available                                                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ VPC Peering
                                     │ Async Replication
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MULTI-REGION DR LAYER                               │
│                              (us-west-2)                                     │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  Standby Node: 1 async replica                                          ││
│  │  • Streaming replication via VPC Peering                                ││
│  │  • Can be promoted to primary                                           ││
│  │  • RPO = minutes (replication lag)                                      ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Recovery Scenarios

| Scenario | Strategy | RTO | RPO |
|----------|----------|-----|-----|
| PostgreSQL node fails | HA automatic failover | ~10s | 0 |
| AZ us-east-1a goes down | HA failover to another AZ | ~10s | 0 |
| Accidental DELETE | PITR restore | ~15min | 5min |
| Data corruption | PITR restore | ~15min | 5min |
| All us-east-1 goes down | Promote DR standby | ~5min | minutes* |
| Regional disaster | Restore from replicated S3 | ~30min | 5min |

*Depends on async replication lag at the time of disaster.

---

### 5. Summary

| Strategy | When to Use | Limitation |
|----------|-------------|------------|
| **HA Only** | Component failures | Doesn't protect against corruption or regional disaster |
| **DR Only** | Disasters and corruption | Downtime during failover (minutes/hours) |
| **HA + DR** | Critical production | Additional infrastructure cost |

#### Recommendation

For production systems with critical data:

```
HA (availability)  +  Local DR (integrity)  +  Multi-Region DR (resilience)
         ↓                    ↓                          ↓
   Common failures        Human errors             Regional disasters
   (automatic)            (manual PITR)            (manual failover)
```

**This project implements all three layers**, providing complete protection from component failures to regional disasters.

---

---

## Português

### Visão Geral

Este documento explica as diferenças entre High Availability (HA), Disaster Recovery (DR) e DR Multi-Region, e por que essas estratégias são complementares e não mutuamente exclusivas.

---

### 1. High Availability (HA)

#### O que é?

HA é a capacidade de um sistema continuar operando mesmo quando componentes individuais falham. O objetivo é **minimizar downtime** através de redundância local.

#### Características

| Aspecto | Descrição |
|---------|-----------|
| **Escopo** | Mesma região/datacenter |
| **Objetivo** | Zero ou mínimo downtime |
| **Failover** | Automático (segundos) |
| **RPO** | Zero (replicação síncrona) |
| **RTO** | Segundos a minutos |

#### Como funciona neste projeto

```
┌─────────────────────────────────────────────────────────┐
│                    us-east-1 (HA Cluster)               │
├─────────────────────────────────────────────────────────┤
│   ┌──────────┐    ┌──────────┐    ┌──────────┐         │
│   │ Patroni  │    │ Patroni  │    │ Patroni  │         │
│   │ Primary  │◄──►│ Replica  │◄──►│ Replica  │         │
│   │  (AZ-a)  │    │  (AZ-b)  │    │  (AZ-c)  │         │
│   └──────────┘    └──────────┘    └──────────┘         │
│        │                │                │              │
│        └────────────────┼────────────────┘              │
│                         ▼                               │
│                 ┌──────────────┐                        │
│                 │  etcd (DCS)  │                        │
│                 │  3 nodes     │                        │
│                 └──────────────┘                        │
└─────────────────────────────────────────────────────────┘
```

**Proteção contra:**
- Falha de instância EC2
- Falha de processo PostgreSQL
- Falha de Availability Zone individual

---

### 2. Disaster Recovery (DR)

#### O que é?

DR é a capacidade de recuperar um sistema após um desastre que afeta toda a infraestrutura primária. O objetivo é **garantir continuidade do negócio** após eventos catastróficos.

#### Características

| Aspecto | Descrição |
|---------|-----------|
| **Escopo** | Região/datacenter alternativo |
| **Objetivo** | Recuperação após desastre total |
| **Failover** | Manual ou semi-automático (minutos/horas) |
| **RPO** | Minutos (replicação assíncrona) |
| **RTO** | Minutos a horas |

#### Tipos de DR

##### DR Local (mesma região, backup/restore)

```
┌──────────────────┐         ┌──────────────────┐
│   HA Cluster     │ ──────► │   S3 Bucket      │
│   (Primary)      │  backup │   (pgBackRest)   │
└──────────────────┘         └──────────────────┘
                                      │
                                      ▼ restore
                             ┌──────────────────┐
                             │   New Instance   │
                             │   (se necessário)│
                             └──────────────────┘
```

**Proteção contra:**
- Corrupção de dados
- Erro humano (DELETE sem WHERE)
- Falha de storage

##### DR Multi-Region (regiões diferentes)

```
┌────────────────────────┐         ┌────────────────────────┐
│      us-east-1         │         │      us-west-2         │
│    (Primary Region)    │         │     (DR Region)        │
├────────────────────────┤         ├────────────────────────┤
│   ┌──────────────┐     │         │   ┌──────────────┐     │
│   │  HA Cluster  │     │ ──────► │   │   Standby    │     │
│   │  (3 nodes)   │     │ async   │   │   (1 node)   │     │
│   └──────────────┘     │ replica │   └──────────────┘     │
│          │             │         │          │             │
│          ▼             │         │          ▼             │
│   ┌──────────────┐     │         │   ┌──────────────┐     │
│   │  S3 Bucket   │─────┼────────►│   │  S3 Bucket   │     │
│   │  (backups)   │ rep │         │   │  (replica)   │     │
│   └──────────────┘     │         │   └──────────────┘     │
└────────────────────────┘         └────────────────────────┘
```

**Proteção contra:**
- Falha completa de região AWS
- Desastres naturais regionais
- Problemas de infraestrutura AWS regionais

---

### 3. Por que HA e DR são Complementares?

#### Diferentes Tipos de Falha

| Tipo de Falha | HA Resolve? | DR Resolve? |
|---------------|-------------|-------------|
| Instância EC2 cai | ✅ Sim | ❌ Overkill |
| Processo PostgreSQL crash | ✅ Sim | ❌ Overkill |
| AZ fica indisponível | ✅ Sim | ❌ Overkill |
| Corrupção de dados | ❌ Não* | ✅ Sim (PITR) |
| DELETE acidental | ❌ Não* | ✅ Sim (PITR) |
| Região inteira cai | ❌ Não | ✅ Sim |
| Ransomware/ataque | ❌ Não* | ✅ Sim (backup offline) |

*HA replica dados corrompidos para todas as réplicas instantaneamente.

#### Analogia

```
HA = Pneu reserva no carro
     → Resolve furos, não resolve acidentes

DR = Seguro do carro + carro reserva
     → Resolve acidentes, mas é lento demais para furos
```

---

### 4. Este Projeto: HA + DR Combinados

#### Arquitetura Completa

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CAMADA HA                                       │
│                           (us-east-1)                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  Patroni Cluster: 3 nodes em 3 AZs                                      ││
│  │  • Failover automático em segundos                                      ││
│  │  • Replicação síncrona (RPO = 0)                                        ││
│  │  • Coordenação via etcd (3 nodes)                                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                          CAMADA DR LOCAL                                ││
│  │  pgBackRest → S3 (mesmo região)                                         ││
│  │  • Full backup semanal                                                  ││
│  │  • Incremental backup diário                                            ││
│  │  • WAL archiving contínuo (RPO = 5 min)                                 ││
│  │  • PITR disponível                                                      ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ VPC Peering
                                     │ Async Replication
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CAMADA DR MULTI-REGION                              │
│                              (us-west-2)                                     │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  Standby Node: 1 réplica assíncrona                                     ││
│  │  • Streaming replication via VPC Peering                                ││
│  │  • Pode ser promovido a primary                                         ││
│  │  • RPO = minutos (lag de replicação)                                    ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Cenários de Recuperação

| Cenário | Estratégia | RTO | RPO |
|---------|------------|-----|-----|
| Node PostgreSQL cai | HA failover automático | ~10s | 0 |
| AZ us-east-1a cai | HA failover para outra AZ | ~10s | 0 |
| DELETE acidental | PITR restore | ~15min | 5min |
| Corrupção de dados | PITR restore | ~15min | 5min |
| us-east-1 inteira cai | Promote DR standby | ~5min | minutos* |
| Desastre regional | Restore do S3 replicado | ~30min | 5min |

*Depende do lag de replicação assíncrona no momento do desastre.

---

### 5. Resumo

| Estratégia | Quando Usar | Limitação |
|------------|-------------|-----------|
| **Apenas HA** | Falhas de componentes | Não protege contra corrupção ou desastre regional |
| **Apenas DR** | Desastres e corrupção | Downtime durante failover (minutos/horas) |
| **HA + DR** | Produção crítica | Custo adicional de infraestrutura |

#### Recomendação

Para sistemas de produção com dados críticos:

```
HA (disponibilidade)  +  DR Local (integridade)  +  DR Multi-Region (resiliência)
         ↓                        ↓                          ↓
   Falhas comuns            Erros humanos              Desastres regionais
   (automático)             (PITR manual)              (failover manual)
```

**Este projeto implementa todas as três camadas**, oferecendo proteção completa para cenários de falha de componente até desastres regionais.
