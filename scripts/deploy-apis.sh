#!/bin/bash
# =============================================================================
# Deploy APIs to EC2 Server
# =============================================================================
# Sets up and deploys the Python and Go APIs on the EC2 API server.
# Run this script on the API server instance via SSM or SSH.
#
# Usage: sudo bash deploy-apis.sh
#
# Prerequisites:
# - Docker images pushed to ECR
# - Instance has IAM role with ECR and SSM permissions
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - Auto-detected from instance metadata and SSM
# =============================================================================

AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
AWS_ACCOUNT_ID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '"accountId"\s*:\s*"\K[^"]+')

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PYTHON_REPO="${ECR_REGISTRY}/pgha-dev-api-python"
ECR_GO_REPO="${ECR_REGISTRY}/pgha-dev-api-go"

# Database config from SSM
SSM_PASSWORD_PARAM="/pgha/postgres-password"
SSM_NLB_PARAM="/pgha/nlb-dns"

DB_PORT="5432"
DB_NAME="postgres"
DB_USER="postgres"
PGBACKREST_STANZA="pgha-dev-postgres"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

get_ssm_param() {
    local param_name="$1"
    aws ssm get-parameter --name "$param_name" --with-decryption --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo ""
}

# =============================================================================
# MAIN
# =============================================================================

log "Starting API deployment..."
log "Region: $AWS_REGION"
log "Account: $AWS_ACCOUNT_ID"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log "Error: Please run as root (sudo)"
    exit 1
fi

# Get dynamic values from SSM
log "Retrieving configuration from SSM..."
DB_PASSWORD=$(get_ssm_param "$SSM_PASSWORD_PARAM")
DB_HOST=$(get_ssm_param "$SSM_NLB_PARAM")

if [ -z "$DB_PASSWORD" ]; then
    log "Error: Failed to retrieve database password from SSM ($SSM_PASSWORD_PARAM)"
    exit 1
fi

if [ -z "$DB_HOST" ]; then
    log "Warning: NLB DNS not in SSM, using tag-based discovery..."
    # Fallback: get NLB DNS from tags (requires ec2 permissions)
    DB_HOST=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName,'pgha')].DNSName" \
        --output text 2>/dev/null | head -1)

    if [ -z "$DB_HOST" ]; then
        log "Error: Could not determine NLB DNS"
        exit 1
    fi
fi

log "Database host: $DB_HOST"

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    dnf update -y
    dnf install -y docker
fi

# Start Docker
log "Starting Docker service..."
systemctl enable docker
systemctl start docker

# Install Docker Compose plugin if not present
if ! docker compose version &> /dev/null; then
    log "Installing Docker Compose plugin..."
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    log "Docker Compose installed: $(docker compose version)"
fi

# Authenticate to ECR
log "Authenticating to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Create /opt/api directory
log "Creating /opt/api directory..."
mkdir -p /opt/api

# Create docker-compose.yml
log "Creating docker-compose.yml..."
cat > /opt/api/docker-compose.yml << EOF
version: '3.8'

services:
  api-python:
    image: ${ECR_PYTHON_REPO}:latest
    container_name: api-python
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - PGBACKREST_STANZA=${PGBACKREST_STANZA}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  api-go:
    image: ${ECR_GO_REPO}:latest
    container_name: api-go
    restart: unless-stopped
    ports:
      - "8001:8000"
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - PGBACKREST_STANZA=${PGBACKREST_STANZA}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# Pull latest images
log "Pulling latest images..."
docker compose -f /opt/api/docker-compose.yml pull

# Start containers
log "Starting containers..."
docker compose -f /opt/api/docker-compose.yml up -d

# Wait for containers to start
log "Waiting for containers to start..."
sleep 10

# Show container status
log "Container status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "N/A")

log ""
log "Deployment complete!"
log ""
log "API Endpoints:"
log "  FastAPI (Python): http://${PUBLIC_IP}:8000/health"
log "  Go API (Gin):     http://${PUBLIC_IP}:8001/health"
log ""
