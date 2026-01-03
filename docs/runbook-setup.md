# Setup Runbook: PostgreSQL HA/DR Complete Setup

**[English](#english)** | **[Português](#português)**

---

## English

This document describes the complete process to provision the PostgreSQL HA/DR cluster from scratch.

---

### Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [AWS Configuration](#2-aws-configuration)
3. [Project Configuration](#3-project-configuration)
4. [Infrastructure Deployment](#4-infrastructure-deployment)
5. [Post-Deployment Verification](#5-post-deployment-verification)
6. [Service Access](#6-service-access)
7. [Common Operations](#7-common-operations)
8. [Troubleshooting](#8-troubleshooting)

---

### 1. Prerequisites

#### Required Tools

| Tool | Minimum Version | Verification |
|------|-----------------|--------------|
| Terraform | >= 1.0 | `terraform version` |
| AWS CLI | >= 2.0 | `aws --version` |
| Docker | >= 20.0 | `docker --version` |
| Git | >= 2.0 | `git --version` |

#### Installation (if needed)

```bash
# Terraform (Windows - chocolatey)
choco install terraform

# Terraform (Linux)
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# AWS CLI
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
```

---

### 2. AWS Configuration

#### 2.1 Create AWS Profile

```bash
# Configure credentials
aws configure --profile postgresql-ha-profile
```

You will be prompted for:
- AWS Access Key ID
- AWS Secret Access Key
- Default region: `us-east-1`
- Default output format: `json`

#### 2.2 Verify Credentials

```bash
aws --profile postgresql-ha-profile sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

#### 2.3 Create Key Pair in AWS (if not exists)

```bash
# Create key pair
aws --profile postgresql-ha-profile ec2 create-key-pair \
    --key-name pgha-key \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/pgha-key.pem

# Adjust permissions
chmod 400 ~/.ssh/pgha-key.pem
```

Or via AWS Console:
1. EC2 → Key Pairs → Create Key Pair
2. Name: `pgha-key` (or your preference)
3. Type: RSA
4. Format: .pem
5. Save the file in a secure location

#### 2.4 Required IAM Permissions

The user/role needs the following permissions:
- `AmazonEC2FullAccess`
- `AmazonS3FullAccess`
- `AmazonSSMFullAccess`
- `AmazonVPCFullAccess`
- `IAMFullAccess`
- `ElasticLoadBalancingFullAccess`
- `AmazonECR-FullAccess` (if using APIs)
- `AmazonSNSFullAccess`
- `CloudWatchLogsFullAccess`
- `AmazonDynamoDBFullAccess` (for state locking)

---

### 3. Project Configuration

#### 3.1 Clone Repository

```bash
git clone <repo-url> postgresql-ha-dr
cd postgresql-ha-dr
```

#### 3.2 Configure Scripts (config.sh)

```bash
# Copy template
cp scripts/config.example.sh scripts/config.sh

# Edit with your values
```

**Edit `scripts/config.sh`:**

```bash
# AWS Profile (must exist in ~/.aws/credentials)
AWS_PROFILE="postgresql-ha-profile"

# AWS Region
AWS_REGION="us-east-1"

# Path to SSH key
# Windows Git Bash: /c/Users/your-user/.ssh/pgha-key.pem
# Linux/Mac:        /home/your-user/.ssh/pgha-key.pem
SSH_KEY_PATH="/path/to/your/key.pem"
```

#### 3.3 Configure Terraform (terraform.tfvars)

```bash
# Copy template
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit with your values
```

**Edit `terraform/terraform.tfvars`:**

```hcl
# ============================================
# REQUIRED - Edit with your values
# ============================================

# Key Pair name in AWS (not the file path)
key_pair_name = "pgha-key"

# Email for alerts (SNS)
alert_email = "your-email@example.com"

# ============================================
# OPTIONAL - Default values work
# ============================================

# Environment
environment = "dev"

# Primary region
aws_region = "us-east-1"

# DR region (only used with --with-dr)
dr_region = "us-west-2"

# Instance type (t3.micro = free tier)
instance_type = "t3.micro"

# Number of Patroni nodes (minimum 2 for HA)
patroni_node_count = 2

# Enable monitoring
enable_monitoring = true
```

#### 3.4 Validate Configuration

```bash
./scripts/setup.sh
```

Expected output:
```
========================================
 PostgreSQL HA/DR - Setup Validation
========================================

1. Checking required tools...
  ✓ Terraform: 1.x.x
  ✓ AWS CLI: aws-cli/2.x.x
  ✓ Docker: 24.x.x

2. Checking configuration files...
  ✓ scripts/config.sh exists
  ✓ AWS_PROFILE: postgresql-ha-profile
  ✓ SSH_KEY_PATH: /path/to/key.pem
  ✓ terraform/terraform.tfvars exists

3. Checking AWS credentials...
  ✓ AWS credentials valid
  i Account: 123456789012
  i Identity: arn:aws:iam::123456789012:user/xxx

4. Checking Terraform state...
  i Terraform not initialized (run: cd terraform && terraform init)

========================================
All checks passed!

Ready to deploy. Run:
  ./scripts/create-cluster.sh
========================================
```

---

### 4. Infrastructure Deployment

#### 4.1 Create Cluster (Primary Region)

```bash
# Interactive (asks for confirmation)
./scripts/create-cluster.sh

# Or without confirmation
./scripts/create-cluster.sh --force

# Skip API build (faster for testing)
./scripts/create-cluster.sh --skip-api
```

**Estimated time:** 8-12 minutes

#### 4.2 Create Cluster with DR (Both Regions)

```bash
./scripts/create-cluster.sh --with-dr
```

**Estimated time:** 15-20 minutes

#### 4.3 What Gets Created

| Component | Quantity | Description |
|-----------|----------|-------------|
| VPC | 1 | 10.0.0.0/16 with 2 public subnets |
| EC2 Patroni | 2-3 | PostgreSQL nodes with Patroni |
| EC2 etcd | 3 | etcd cluster for coordination |
| EC2 Bastion | 1 | Jump host for SSH access |
| EC2 Monitoring | 1 | Prometheus + Grafana |
| EC2 API Server | 1 | Python/Go APIs |
| NLB | 1 | Load balancer for PostgreSQL |
| S3 | 2 | Backups (pgBackRest) + Terraform state |
| ECR | 2 | Docker repositories for APIs |
| SSM Parameters | 4 | Passwords (postgres, replication, etc.) |
| SNS Topic | 1 | Alerts |

---

### 5. Post-Deployment Verification

#### 5.1 Complete Health Check

```bash
./scripts/health-check.sh
```

#### 5.2 Verify Patroni

```bash
# Via SSM (without SSH key)
INSTANCE_ID=$(cd terraform && terraform output -json patroni_instance_ids | grep -oE 'i-[a-z0-9]+' | head -1)
aws --profile postgresql-ha-profile ssm start-session --target $INSTANCE_ID

# Inside the instance:
sudo patronictl -c /etc/patroni/patroni.yml list
```

Expected output:
```
+ Cluster: pgha-dev-postgres ------+---------+---------+----+-----------+
| Member           | Host         | Role    | State   | TL | Lag in MB |
+------------------+--------------+---------+---------+----+-----------+
| pgha-dev-patroni-1 | 10.0.1.x   | Leader  | running |  1 |           |
| pgha-dev-patroni-2 | 10.0.1.y   | Replica | running |  1 |         0 |
+------------------+--------------+---------+---------+----+-----------+
```

#### 5.3 Verify PostgreSQL Connectivity

```bash
# Get NLB DNS
NLB_DNS=$(cd terraform && terraform output -raw nlb_dns_name)

# Get password
PGPASSWORD=$(aws --profile postgresql-ha-profile ssm get-parameter \
    --name /pgha/postgres-password \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text)

# Test connection (from bastion or via tunnel)
psql -h $NLB_DNS -p 5432 -U postgres -c "SELECT version();"
```

---

### 6. Service Access

#### 6.1 Access Information

After deployment, the script shows all information. To retrieve:

```bash
cd terraform

# NLB DNS (PostgreSQL)
terraform output nlb_dns_name

# Bastion IP
terraform output bastion_public_ip

# Monitoring IP (private)
terraform output monitoring_private_ip

# API Server IP (private)
terraform output api_server_private_ip

# PostgreSQL password
aws --profile postgresql-ha-profile ssm get-parameter \
    --name /pgha/postgres-password \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
```

#### 6.2 SSH to Bastion

```bash
# Get IP
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)

# Connect
ssh -i "$SSH_KEY_PATH" ec2-user@$BASTION_IP
```

#### 6.3 SSH Tunnel for Internal Services

```bash
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)
MONITORING_IP=$(cd terraform && terraform output -raw monitoring_private_ip)
API_IP=$(cd terraform && terraform output -raw api_server_private_ip)

# Tunnel for Grafana (3000), Prometheus (9090), APIs (8000, 8001)
ssh -i "$SSH_KEY_PATH" \
    -L 3000:$MONITORING_IP:3000 \
    -L 9090:$MONITORING_IP:9090 \
    -L 8000:$API_IP:8000 \
    -L 8001:$API_IP:8001 \
    ec2-user@$BASTION_IP
```

With active tunnel:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090
- Python API: http://localhost:8000/health
- Go API: http://localhost:8001/health

#### 6.4 SSM Session (Without SSH Key)

```bash
# List instances
aws --profile postgresql-ha-profile ec2 describe-instances \
    --filters "Name=tag:Name,Values=pgha-*" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name'].Value|[0]]" \
    --output table

# Connect via SSM
aws --profile postgresql-ha-profile ssm start-session --target <instance-id>
```

---

### 7. Common Operations

#### 7.1 Backup

```bash
# Full backup
./scripts/backup-full.sh

# Incremental backup
./scripts/backup-incr.sh

# Verify backups
./scripts/verify-backup.sh
```

#### 7.2 Restore (PITR)

```bash
# Restore to specific point
./scripts/restore-pitr.sh "2025-01-15 14:30:00"
```

#### 7.3 Failover Test

```bash
# Simulate leader failure
./scripts/chaos-test.sh
```

#### 7.4 Monitoring

```bash
# Real-time status
./scripts/monitor-cluster.sh

# Health check
./scripts/health-check.sh
```

#### 7.5 API Deployment

```bash
# If skipped --skip-api on create, can do later:
# 1. Build and push to ECR (from your machine)
cd api && docker build -t <ecr-url>:latest . && docker push <ecr-url>:latest

# 2. Deploy on server (via SSM)
# Copy scripts/deploy-apis.sh to API server and execute
```

---

### 8. Troubleshooting

#### 8.1 Terraform Init Fails (Lock File)

```bash
cd terraform
terraform init -upgrade
```

#### 8.2 SSM Session Won't Connect

Check:
1. Instance is running
2. IAM role has `AmazonSSMManagedInstanceCore`
3. SSM Agent is running on instance

```bash
# Check SSM status
aws --profile postgresql-ha-profile ssm describe-instance-information \
    --query "InstanceInformationList[].{Id:InstanceId,Status:PingStatus}"
```

#### 8.3 Patroni Won't Form Cluster

```bash
# Check logs
sudo journalctl -u patroni -f

# Check etcd
etcdctl --endpoints=http://10.0.1.x:2379 member list
```

#### 8.4 NLB Health Checks Failing

```bash
# Check target group health
aws --profile postgresql-ha-profile elbv2 describe-target-health \
    --target-group-arn <target-group-arn>

# Check if Patroni is responding
curl http://localhost:8008/health
```

#### 8.5 Destroy Everything and Start Over

```bash
# Complete destruction
./scripts/destroy-cluster.sh --force

# Clean local state (if needed)
cd terraform
rm -rf .terraform terraform.tfstate*

# Start over
terraform init
./scripts/create-cluster.sh
```

---

### Quick Reference Variables

#### scripts/config.sh

| Variable | Description | Example |
|----------|-------------|---------|
| `AWS_PROFILE` | AWS CLI profile | `postgresql-ha-profile` |
| `AWS_REGION` | Primary region | `us-east-1` |
| `SSH_KEY_PATH` | Path to .pem key | `/home/user/.ssh/key.pem` |

#### terraform/terraform.tfvars

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `key_pair_name` | Yes | Key pair name in AWS | - |
| `alert_email` | Yes | Email for SNS alerts | - |
| `environment` | No | Environment (dev/staging/prod) | `dev` |
| `aws_region` | No | Primary region | `us-east-1` |
| `instance_type` | No | EC2 type | `t3.micro` |
| `patroni_node_count` | No | Number of PostgreSQL nodes | `2` |
| `enable_monitoring` | No | Enable Prometheus/Grafana | `true` |

---

### Estimated Costs

| Component | Monthly (USD) |
|-----------|---------------|
| EC2 (8x t3.micro) | ~$0 (Free Tier) |
| NLB | ~$16 |
| S3 | ~$1 |
| Data Transfer | ~$2 |
| **Total** | **~$20** |

**Tip:** Destroy infrastructure when not in use to save money.

```bash
./scripts/destroy-cluster.sh
```

---

---

## Português

Este documento descreve o processo completo para provisionar o cluster PostgreSQL HA/DR do zero.

---

### Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Configuração AWS](#2-configuração-aws)
3. [Configuração do Projeto](#3-configuração-do-projeto)
4. [Deploy da Infraestrutura](#4-deploy-da-infraestrutura)
5. [Verificação Pós-Deploy](#5-verificação-pós-deploy)
6. [Acesso aos Serviços](#6-acesso-aos-serviços)
7. [Operações Comuns](#7-operações-comuns)
8. [Troubleshooting](#8-troubleshooting-pt)

---

### 1. Pré-requisitos

#### Ferramentas Necessárias

| Ferramenta | Versão Mínima | Verificação |
|------------|---------------|-------------|
| Terraform | >= 1.0 | `terraform version` |
| AWS CLI | >= 2.0 | `aws --version` |
| Docker | >= 20.0 | `docker --version` |
| Git | >= 2.0 | `git --version` |

#### Instalação (se necessário)

```bash
# Terraform (Windows - chocolatey)
choco install terraform

# Terraform (Linux)
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# AWS CLI
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
```

---

### 2. Configuração AWS

#### 2.1 Criar Perfil AWS

```bash
# Configurar credenciais
aws configure --profile postgresql-ha-profile
```

Será solicitado:
- AWS Access Key ID
- AWS Secret Access Key
- Default region: `us-east-1`
- Default output format: `json`

#### 2.2 Verificar Credenciais

```bash
aws --profile postgresql-ha-profile sts get-caller-identity
```

Saída esperada:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/seu-usuario"
}
```

#### 2.3 Criar Key Pair na AWS (se não existir)

```bash
# Criar key pair
aws --profile postgresql-ha-profile ec2 create-key-pair \
    --key-name pgha-key \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/pgha-key.pem

# Ajustar permissões
chmod 400 ~/.ssh/pgha-key.pem
```

Ou via Console AWS:
1. EC2 → Key Pairs → Create Key Pair
2. Nome: `pgha-key` (ou outro de sua preferência)
3. Tipo: RSA
4. Formato: .pem
5. Salvar o arquivo em local seguro

#### 2.4 Permissões IAM Necessárias

O usuário/role precisa das seguintes permissões:
- `AmazonEC2FullAccess`
- `AmazonS3FullAccess`
- `AmazonSSMFullAccess`
- `AmazonVPCFullAccess`
- `IAMFullAccess`
- `ElasticLoadBalancingFullAccess`
- `AmazonECR-FullAccess` (se usar APIs)
- `AmazonSNSFullAccess`
- `CloudWatchLogsFullAccess`
- `AmazonDynamoDBFullAccess` (para state locking)

---

### 3. Configuração do Projeto

#### 3.1 Clonar Repositório

```bash
git clone <repo-url> postgresql-ha-dr
cd postgresql-ha-dr
```

#### 3.2 Configurar Scripts (config.sh)

```bash
# Copiar template
cp scripts/config.example.sh scripts/config.sh

# Editar com seus valores
```

**Editar `scripts/config.sh`:**

```bash
# AWS Profile (deve existir em ~/.aws/credentials)
AWS_PROFILE="postgresql-ha-profile"

# AWS Region
AWS_REGION="us-east-1"

# Caminho para a chave SSH
# Windows Git Bash: /c/Users/seu-usuario/.ssh/pgha-key.pem
# Linux/Mac:        /home/seu-usuario/.ssh/pgha-key.pem
SSH_KEY_PATH="/caminho/para/sua/chave.pem"
```

#### 3.3 Configurar Terraform (terraform.tfvars)

```bash
# Copiar template
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Editar com seus valores
```

**Editar `terraform/terraform.tfvars`:**

```hcl
# ============================================
# OBRIGATÓRIO - Editar com seus valores
# ============================================

# Nome do Key Pair na AWS (não o caminho do arquivo)
key_pair_name = "pgha-key"

# Email para alertas (SNS)
alert_email = "seu-email@exemplo.com"

# ============================================
# OPCIONAL - Valores padrão funcionam
# ============================================

# Ambiente
environment = "dev"

# Região primária
aws_region = "us-east-1"

# Região DR (só usado com --with-dr)
dr_region = "us-west-2"

# Tipo de instância (t3.micro = free tier)
instance_type = "t3.micro"

# Número de nós Patroni (mínimo 2 para HA)
patroni_node_count = 2

# Habilitar monitoramento
enable_monitoring = true
```

#### 3.4 Validar Configuração

```bash
./scripts/setup.sh
```

Saída esperada:
```
========================================
 PostgreSQL HA/DR - Setup Validation
========================================

1. Checking required tools...
  ✓ Terraform: 1.x.x
  ✓ AWS CLI: aws-cli/2.x.x
  ✓ Docker: 24.x.x

2. Checking configuration files...
  ✓ scripts/config.sh exists
  ✓ AWS_PROFILE: postgresql-ha-profile
  ✓ SSH_KEY_PATH: /path/to/key.pem
  ✓ terraform/terraform.tfvars exists

3. Checking AWS credentials...
  ✓ AWS credentials valid
  i Account: 123456789012
  i Identity: arn:aws:iam::123456789012:user/xxx

4. Checking Terraform state...
  i Terraform not initialized (run: cd terraform && terraform init)

========================================
All checks passed!

Ready to deploy. Run:
  ./scripts/create-cluster.sh
========================================
```

---

### 4. Deploy da Infraestrutura

#### 4.1 Criar Cluster (Região Primária)

```bash
# Interativo (pede confirmação)
./scripts/create-cluster.sh

# Ou sem confirmação
./scripts/create-cluster.sh --force

# Pular build das APIs (mais rápido para teste)
./scripts/create-cluster.sh --skip-api
```

**Tempo estimado:** 8-12 minutos

#### 4.2 Criar Cluster com DR (Ambas Regiões)

```bash
./scripts/create-cluster.sh --with-dr
```

**Tempo estimado:** 15-20 minutos

#### 4.3 O que é Criado

| Componente | Quantidade | Descrição |
|------------|------------|-----------|
| VPC | 1 | 10.0.0.0/16 com 2 subnets públicas |
| EC2 Patroni | 2-3 | Nós PostgreSQL com Patroni |
| EC2 etcd | 3 | Cluster etcd para coordenação |
| EC2 Bastion | 1 | Jump host para acesso SSH |
| EC2 Monitoring | 1 | Prometheus + Grafana |
| EC2 API Server | 1 | APIs Python/Go |
| NLB | 1 | Load balancer para PostgreSQL |
| S3 | 2 | Backups (pgBackRest) + Terraform state |
| ECR | 2 | Repositórios Docker para APIs |
| SSM Parameters | 4 | Senhas (postgres, replication, etc.) |
| SNS Topic | 1 | Alertas |

---

### 5. Verificação Pós-Deploy

#### 5.1 Health Check Completo

```bash
./scripts/health-check.sh
```

#### 5.2 Verificar Patroni

```bash
# Via SSM (sem SSH key)
INSTANCE_ID=$(cd terraform && terraform output -json patroni_instance_ids | grep -oE 'i-[a-z0-9]+' | head -1)
aws --profile postgresql-ha-profile ssm start-session --target $INSTANCE_ID

# Dentro da instância:
sudo patronictl -c /etc/patroni/patroni.yml list
```

Saída esperada:
```
+ Cluster: pgha-dev-postgres ------+---------+---------+----+-----------+
| Member           | Host         | Role    | State   | TL | Lag in MB |
+------------------+--------------+---------+---------+----+-----------+
| pgha-dev-patroni-1 | 10.0.1.x   | Leader  | running |  1 |           |
| pgha-dev-patroni-2 | 10.0.1.y   | Replica | running |  1 |         0 |
+------------------+--------------+---------+---------+----+-----------+
```

#### 5.3 Verificar Conectividade PostgreSQL

```bash
# Obter NLB DNS
NLB_DNS=$(cd terraform && terraform output -raw nlb_dns_name)

# Obter senha
PGPASSWORD=$(aws --profile postgresql-ha-profile ssm get-parameter \
    --name /pgha/postgres-password \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text)

# Testar conexão (do bastion ou via túnel)
psql -h $NLB_DNS -p 5432 -U postgres -c "SELECT version();"
```

---

### 6. Acesso aos Serviços

#### 6.1 Informações de Acesso

Após o deploy, o script mostra todas as informações. Para recuperar:

```bash
cd terraform

# NLB DNS (PostgreSQL)
terraform output nlb_dns_name

# Bastion IP
terraform output bastion_public_ip

# Monitoring IP (privado)
terraform output monitoring_private_ip

# API Server IP (privado)
terraform output api_server_private_ip

# Senha PostgreSQL
aws --profile postgresql-ha-profile ssm get-parameter \
    --name /pgha/postgres-password \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
```

#### 6.2 SSH para Bastion

```bash
# Obter IP
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)

# Conectar
ssh -i "$SSH_KEY_PATH" ec2-user@$BASTION_IP
```

#### 6.3 Túnel SSH para Serviços Internos

```bash
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)
MONITORING_IP=$(cd terraform && terraform output -raw monitoring_private_ip)
API_IP=$(cd terraform && terraform output -raw api_server_private_ip)

# Túnel para Grafana (3000), Prometheus (9090), APIs (8000, 8001)
ssh -i "$SSH_KEY_PATH" \
    -L 3000:$MONITORING_IP:3000 \
    -L 9090:$MONITORING_IP:9090 \
    -L 8000:$API_IP:8000 \
    -L 8001:$API_IP:8001 \
    ec2-user@$BASTION_IP
```

Com o túnel ativo:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090
- Python API: http://localhost:8000/health
- Go API: http://localhost:8001/health

#### 6.4 SSM Session (Sem SSH Key)

```bash
# Listar instâncias
aws --profile postgresql-ha-profile ec2 describe-instances \
    --filters "Name=tag:Name,Values=pgha-*" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name'].Value|[0]]" \
    --output table

# Conectar via SSM
aws --profile postgresql-ha-profile ssm start-session --target <instance-id>
```

---

### 7. Operações Comuns

#### 7.1 Backup

```bash
# Backup completo
./scripts/backup-full.sh

# Backup incremental
./scripts/backup-incr.sh

# Verificar backups
./scripts/verify-backup.sh
```

#### 7.2 Restore (PITR)

```bash
# Restore para ponto específico
./scripts/restore-pitr.sh "2025-01-15 14:30:00"
```

#### 7.3 Teste de Failover

```bash
# Simular falha do leader
./scripts/chaos-test.sh
```

#### 7.4 Monitoramento

```bash
# Status em tempo real
./scripts/monitor-cluster.sh

# Health check
./scripts/health-check.sh
```

#### 7.5 Deploy das APIs

```bash
# Se pulou --skip-api no create, pode fazer depois:
# 1. Build e push para ECR (da sua máquina)
cd api && docker build -t <ecr-url>:latest . && docker push <ecr-url>:latest

# 2. Deploy no servidor (via SSM)
# Copiar scripts/deploy-apis.sh para o API server e executar
```

---

### 8. Troubleshooting {#troubleshooting-pt}

#### 8.1 Terraform Init Falha (Lock File)

```bash
cd terraform
terraform init -upgrade
```

#### 8.2 SSM Session Não Conecta

Verificar:
1. Instância está running
2. IAM role tem `AmazonSSMManagedInstanceCore`
3. SSM Agent está rodando na instância

```bash
# Verificar status SSM
aws --profile postgresql-ha-profile ssm describe-instance-information \
    --query "InstanceInformationList[].{Id:InstanceId,Status:PingStatus}"
```

#### 8.3 Patroni Não Forma Cluster

```bash
# Verificar logs
sudo journalctl -u patroni -f

# Verificar etcd
etcdctl --endpoints=http://10.0.1.x:2379 member list
```

#### 8.4 NLB Health Checks Falhando

```bash
# Verificar target group health
aws --profile postgresql-ha-profile elbv2 describe-target-health \
    --target-group-arn <target-group-arn>

# Verificar se Patroni está respondendo
curl http://localhost:8008/health
```

#### 8.5 Destruir Tudo e Recomeçar

```bash
# Destruir completamente
./scripts/destroy-cluster.sh --force

# Limpar state local (se necessário)
cd terraform
rm -rf .terraform terraform.tfstate*

# Recomeçar
terraform init
./scripts/create-cluster.sh
```

---

### Variáveis de Referência Rápida

#### scripts/config.sh

| Variável | Descrição | Exemplo |
|----------|-----------|---------|
| `AWS_PROFILE` | Perfil AWS CLI | `postgresql-ha-profile` |
| `AWS_REGION` | Região primária | `us-east-1` |
| `SSH_KEY_PATH` | Caminho da chave .pem | `/home/user/.ssh/key.pem` |

#### terraform/terraform.tfvars

| Variável | Obrigatório | Descrição | Default |
|----------|-------------|-----------|---------|
| `key_pair_name` | Sim | Nome do key pair na AWS | - |
| `alert_email` | Sim | Email para alertas SNS | - |
| `environment` | Não | Ambiente (dev/staging/prod) | `dev` |
| `aws_region` | Não | Região primária | `us-east-1` |
| `instance_type` | Não | Tipo EC2 | `t3.micro` |
| `patroni_node_count` | Não | Número de nós PostgreSQL | `2` |
| `enable_monitoring` | Não | Habilitar Prometheus/Grafana | `true` |

---

### Custos Estimados

| Componente | Mensal (USD) |
|------------|--------------|
| EC2 (8x t3.micro) | ~$0 (Free Tier) |
| NLB | ~$16 |
| S3 | ~$1 |
| Data Transfer | ~$2 |
| **Total** | **~$20** |

**Dica:** Destrua a infraestrutura quando não estiver usando para economizar.

```bash
./scripts/destroy-cluster.sh
```
