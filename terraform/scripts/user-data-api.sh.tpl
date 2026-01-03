#!/bin/bash
# =============================================================================
# API Server User Data Script
# =============================================================================
# Installs Docker and runs both Python (FastAPI) and Go (Gin) APIs
# Images are pulled from ECR
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration (from Terraform)
# -----------------------------------------------------------------------------
AWS_REGION="${aws_region}"
ECR_PYTHON_REPO="${ecr_python_repo}"
ECR_GO_REPO="${ecr_go_repo}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
DB_NAME="${db_name}"
DB_USER="${db_user}"
SSM_PASSWORD_PARAM="${ssm_password_param}"
PGBACKREST_STANZA="${pgbackrest_stanza}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting API Server setup..."

# -----------------------------------------------------------------------------
# System Updates
# -----------------------------------------------------------------------------
log "Updating system packages..."
dnf update -y
dnf install -y docker jq

# -----------------------------------------------------------------------------
# Docker Setup
# -----------------------------------------------------------------------------
log "Configuring Docker..."
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Install Docker Compose (standalone binary - Amazon Linux 2023 doesn't have plugin)
log "Installing Docker Compose..."
curl -SL https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# -----------------------------------------------------------------------------
# ECR Authentication
# -----------------------------------------------------------------------------
log "Authenticating to ECR..."
ECR_REGISTRY=$(echo "$ECR_PYTHON_REPO" | cut -d'/' -f1)
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# -----------------------------------------------------------------------------
# Get Database Password from SSM
# -----------------------------------------------------------------------------
log "Retrieving database password from SSM..."
DB_PASSWORD_RAW=$(aws ssm get-parameter --name "$SSM_PASSWORD_PARAM" --with-decryption --region $AWS_REGION --query 'Parameter.Value' --output text)

# Escape $ characters for docker-compose ($ -> $$)
# Docker Compose interprets $VAR as variable substitution, $$ escapes to literal $
# Using bash parameter expansion which is more reliable than sed through heredocs
DB_PASSWORD_ESCAPED="${DB_PASSWORD_RAW//\$/\$\$}"

# -----------------------------------------------------------------------------
# Create Docker Compose Configuration
# -----------------------------------------------------------------------------
log "Creating Docker Compose configuration..."

mkdir -p /opt/api

# Write password to .env file (read via env_file directive)
# This avoids YAML variable interpolation issues
echo "DB_PASSWORD=$DB_PASSWORD_ESCAPED" > /opt/api/.env
chmod 600 /opt/api/.env

# Create docker-compose.yml using env_file for password
cat > /opt/api/docker-compose.yml << COMPOSE_EOF
version: '3.8'

services:
  api-python:
    image: ECR_PYTHON_REPO_PLACEHOLDER:latest
    container_name: api-python
    restart: unless-stopped
    ports:
      - "8000:8000"
    env_file:
      - .env
    environment:
      - DB_HOST=DB_HOST_PLACEHOLDER
      - DB_PORT=DB_PORT_PLACEHOLDER
      - DB_NAME=DB_NAME_PLACEHOLDER
      - DB_USER=DB_USER_PLACEHOLDER
      - PGBACKREST_STANZA=PGBACKREST_STANZA_PLACEHOLDER
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
    image: ECR_GO_REPO_PLACEHOLDER:latest
    container_name: api-go
    restart: unless-stopped
    ports:
      - "8001:8000"
    env_file:
      - .env
    environment:
      - DB_HOST=DB_HOST_PLACEHOLDER
      - DB_PORT=DB_PORT_PLACEHOLDER
      - DB_NAME=DB_NAME_PLACEHOLDER
      - DB_USER=DB_USER_PLACEHOLDER
      - PGBACKREST_STANZA=PGBACKREST_STANZA_PLACEHOLDER
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
COMPOSE_EOF

# Replace placeholders with actual values (avoids variable interpretation issues)
sed -i "s|ECR_PYTHON_REPO_PLACEHOLDER|$ECR_PYTHON_REPO|g" /opt/api/docker-compose.yml
sed -i "s|ECR_GO_REPO_PLACEHOLDER|$ECR_GO_REPO|g" /opt/api/docker-compose.yml
sed -i "s|DB_HOST_PLACEHOLDER|$DB_HOST|g" /opt/api/docker-compose.yml
sed -i "s|DB_PORT_PLACEHOLDER|$DB_PORT|g" /opt/api/docker-compose.yml
sed -i "s|DB_NAME_PLACEHOLDER|$DB_NAME|g" /opt/api/docker-compose.yml
sed -i "s|DB_USER_PLACEHOLDER|$DB_USER|g" /opt/api/docker-compose.yml
sed -i "s|PGBACKREST_STANZA_PLACEHOLDER|$PGBACKREST_STANZA|g" /opt/api/docker-compose.yml

# -----------------------------------------------------------------------------
# Create Systemd Service for Docker Compose
# -----------------------------------------------------------------------------
log "Creating systemd service..."

cat > /etc/systemd/system/api-server.service << EOF
[Unit]
Description=API Server (Docker Compose)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/api
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Create ECR Re-authentication Script (for image pulls)
# -----------------------------------------------------------------------------
log "Creating ECR re-auth script..."

cat > /opt/api/ecr-login.sh << EOF
#!/bin/bash
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
EOF
chmod +x /opt/api/ecr-login.sh

# Create cron job for ECR re-authentication (tokens expire after 12 hours)
echo "0 */10 * * * root /opt/api/ecr-login.sh >> /var/log/ecr-login.log 2>&1" > /etc/cron.d/ecr-login

# -----------------------------------------------------------------------------
# Create Update Script
# -----------------------------------------------------------------------------
log "Creating update script..."

cat > /opt/api/update-apis.sh << SCRIPT
#!/bin/bash
# Script to update API containers with latest images

set -e

cd /opt/api

# Re-authenticate to ECR
./ecr-login.sh

# Pull latest images
docker-compose pull

# Restart with new images
docker-compose up -d

# Cleanup old images
docker image prune -f

echo "APIs updated successfully at $(date)"
SCRIPT
chmod +x /opt/api/update-apis.sh

# -----------------------------------------------------------------------------
# Start Services
# -----------------------------------------------------------------------------
log "Enabling and starting API server..."
systemctl daemon-reload
systemctl enable api-server

# Note: We don't start the service here because images need to be pushed to ECR first
# The service will start on next boot or can be started manually after pushing images

# -----------------------------------------------------------------------------
# Create Health Check Script
# -----------------------------------------------------------------------------
cat > /opt/api/health-check.sh << EOF
#!/bin/bash
echo "=== API Health Check ==="
echo ""
echo "Python API (FastAPI) - Port 8000:"
curl -s http://localhost:8000/health 2>/dev/null || echo "Not responding"
echo ""
echo ""
echo "Go API (Gin) - Port 8001:"
curl -s http://localhost:8001/health 2>/dev/null || echo "Not responding"
echo ""
echo ""
echo "=== Container Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF
chmod +x /opt/api/health-check.sh

# -----------------------------------------------------------------------------
# Final Message
# -----------------------------------------------------------------------------
log "API Server setup complete!"
log ""
log "IMPORTANT: Push images to ECR before starting the service:"
log "  1. Build and push images to ECR (see terraform output for commands)"
log "  2. SSH to this server and run: sudo systemctl start api-server"
log ""
log "Or run the update script after pushing images:"
log "  sudo /opt/api/update-apis.sh"
log ""
log "Health check: /opt/api/health-check.sh"
