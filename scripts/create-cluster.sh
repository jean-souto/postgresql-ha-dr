#!/bin/bash
# =============================================================================
# Create PostgreSQL HA/DR Cluster - Complete Setup
# =============================================================================
# Creates all infrastructure using Terraform and initializes services.
#
# Usage:
#   ./create-cluster.sh              # Interactive (primary region only)
#   ./create-cluster.sh --force      # Skip confirmation
#   ./create-cluster.sh --with-dr    # Include DR region (us-west-2)
#   ./create-cluster.sh --skip-api   # Skip API image build/push
#
# Requirements:
#   - Terraform installed and in PATH
#   - AWS CLI configured (profile: postgresql-ha-profile)
#   - Docker installed (for API deployment, unless --skip-api)
# =============================================================================

set -e

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared config (provides AWS_PROFILE, AWS_REGION, colors, helpers)
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "ERROR: config.sh not found. Run: cp scripts/config.example.sh scripts/config.sh"
    exit 1
fi
export PGHA_SILENT=true
source "$SCRIPT_DIR/config.sh"
unset PGHA_SILENT

# Region configuration
PRIMARY_REGION="${AWS_REGION:-us-east-1}"
DR_REGION="us-west-2"
PROFILE="$AWS_PROFILE"

# Parse arguments
FORCE=false
WITH_DR=false
SKIP_API=false

for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE=true
            ;;
        --with-dr)
            WITH_DR=true
            ;;
        --skip-api)
            SKIP_API=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f   Skip confirmation prompt"
            echo "  --with-dr     Also create DR region (us-west-2)"
            echo "  --skip-api    Skip API image build and push to ECR"
            exit 0
            ;;
    esac
done

# Note: Colors, paths, and log functions come from config.sh

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
    log_step "Running pre-flight checks..."

    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform not found. Please install Terraform."
        exit 1
    fi
    log_info "Terraform: $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)"

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    log_info "AWS CLI: $(aws --version 2>&1 | cut -d' ' -f1)"

    # Check AWS credentials
    if ! aws sts get-caller-identity --profile "$PROFILE" &> /dev/null; then
        log_error "AWS credentials not valid for profile: $PROFILE"
        exit 1
    fi

    local account_id
    account_id=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
    log_info "AWS Account: $account_id"
    log_info "AWS Profile: $PROFILE"

    # Check Docker (if building API)
    if [[ "$SKIP_API" == "false" ]]; then
        if ! command -v docker &> /dev/null; then
            log_warn "Docker not found. Skipping API deployment."
            SKIP_API=true
        else
            log_info "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
        fi
    fi

    echo ""
}

# =============================================================================
# Wait Functions
# =============================================================================

wait_for_instances() {
    local max_attempts=30
    local attempt=1
    local wait_seconds=20

    log_info "Waiting for instances to be ready (SSM connectivity)..."

    while [[ $attempt -le $max_attempts ]]; do
        cd "$TERRAFORM_DIR"
        local patroni_ids=$(terraform output -json patroni_instance_ids 2>/dev/null | grep -oE 'i-[a-z0-9]+' || true)

        if [[ -z "$patroni_ids" ]]; then
            log_warn "Waiting for Terraform outputs... (attempt $attempt/$max_attempts)"
            sleep $wait_seconds
            ((attempt++))
            continue
        fi

        local first_id=$(echo "$patroni_ids" | head -1)
        local ssm_status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$first_id" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text \
            --profile $PROFILE 2>/dev/null || echo "Unknown")

        if [[ "$ssm_status" == "Online" ]]; then
            log_success "Instances are ready (SSM Online)"
            return 0
        fi

        log_info "Waiting for SSM... (attempt $attempt/$max_attempts, status: $ssm_status)"
        sleep $wait_seconds
        ((attempt++))
    done

    log_warn "Timeout waiting for SSM. Instances may still be starting."
    return 0
}

wait_for_patroni() {
    local max_attempts=20
    local attempt=1
    local wait_seconds=15

    log_info "Waiting for Patroni cluster to form..."

    while [[ $attempt -le $max_attempts ]]; do
        cd "$TERRAFORM_DIR"
        local patroni_id=$(terraform output -json patroni_instance_ids 2>/dev/null | grep -oE 'i-[a-z0-9]+' | head -1 || true)

        if [[ -z "$patroni_id" ]]; then
            sleep $wait_seconds
            ((attempt++))
            continue
        fi

        local cmd_id=$(aws ssm send-command \
            --instance-ids "$patroni_id" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["curl -s http://localhost:8008/patroni 2>/dev/null || echo ERROR"]' \
            --output text \
            --query 'Command.CommandId' \
            --profile $PROFILE 2>/dev/null || true)

        if [[ -n "$cmd_id" ]]; then
            sleep 3
            local result=$(aws ssm get-command-invocation \
                --command-id "$cmd_id" \
                --instance-id "$patroni_id" \
                --query 'StandardOutputContent' \
                --output text \
                --profile $PROFILE 2>/dev/null || echo "ERROR")

            if [[ "$result" != *"ERROR"* ]] && [[ "$result" == *"running"* ]]; then
                log_success "Patroni is running"
                return 0
            fi
        fi

        log_info "Waiting for Patroni... (attempt $attempt/$max_attempts)"
        sleep $wait_seconds
        ((attempt++))
    done

    log_warn "Patroni may not be fully ready. Run ./scripts/health-check.sh to verify."
    return 0
}

# =============================================================================
# Terraform Apply - Primary Region
# =============================================================================

apply_primary() {
    log_step "Step 1/4: Applying Primary Region ($PRIMARY_REGION)..."

    cd "$TERRAFORM_DIR"

    # Check Terraform is initialized
    if [[ ! -d ".terraform" ]]; then
        log_info "Initializing Terraform..."
        terraform init -input=false
    fi

    # Show plan summary
    log_info "Planning infrastructure..."
    terraform plan -out=tfplan -input=false > /dev/null 2>&1 || true

    PLAN_SUMMARY=$(terraform show -no-color tfplan 2>/dev/null | grep -E "Plan:|No changes" | head -1 || echo "Plan ready")
    echo "$PLAN_SUMMARY"
    echo ""

    # Confirmation
    if [[ "$FORCE" != "true" ]]; then
        echo -e "${YELLOW}This will create/update the PostgreSQL HA infrastructure.${NC}"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warn "Aborted. No changes made."
            rm -f tfplan
            exit 1
        fi
    fi

    # Apply
    log_info "Creating infrastructure..."
    START_TIME=$(date +%s)

    terraform apply -auto-approve tfplan
    rm -f tfplan

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    log_success "Primary region created in ${DURATION}s"
}

# =============================================================================
# Build and Push API Images
# =============================================================================

build_and_push_apis() {
    if [[ "$SKIP_API" == "true" ]]; then
        log_info "Step 2/4: Skipping API build (--skip-api)"
        return 0
    fi

    log_step "Step 2/4: Building and pushing API images to ECR..."

    cd "$TERRAFORM_DIR"

    # Get ECR URLs
    local python_repo=$(terraform output -raw ecr_repository_python_url 2>/dev/null || echo "")
    local go_repo=$(terraform output -raw ecr_repository_go_url 2>/dev/null || echo "")

    if [[ -z "$python_repo" ]]; then
        log_warn "ECR repository not found. Skipping API build."
        return 0
    fi

    # Get registry URL (strip repo name)
    local registry=$(echo "$python_repo" | cut -d'/' -f1)

    # Login to ECR
    log_info "Logging in to ECR..."
    aws ecr get-login-password --region "$PRIMARY_REGION" --profile "$PROFILE" | \
        docker login --username AWS --password-stdin "$registry"

    # Build and push Python API
    if [[ -d "$PROJECT_ROOT/api" ]]; then
        log_info "Building Python API..."
        cd "$PROJECT_ROOT/api"
        docker build -t "$python_repo:latest" .
        docker push "$python_repo:latest"
        log_success "Python API pushed to ECR"
    fi

    # Build and push Go API
    if [[ -d "$PROJECT_ROOT/api-go" ]]; then
        log_info "Building Go API..."
        cd "$PROJECT_ROOT/api-go"
        docker build -t "$go_repo:latest" .
        docker push "$go_repo:latest"
        log_success "Go API pushed to ECR"
    fi
}

# =============================================================================
# Apply DR Region (if enabled)
# =============================================================================

apply_dr_region() {
    if [[ "$WITH_DR" != "true" ]]; then
        log_info "Step 3/4: Skipping DR region (use --with-dr to enable)"
        return 0
    fi

    log_step "Step 3/4: Applying DR Region ($DR_REGION)..."

    if [[ ! -d "$DR_TERRAFORM_DIR" ]]; then
        log_warn "DR region terraform not found at $DR_TERRAFORM_DIR"
        return 0
    fi

    cd "$DR_TERRAFORM_DIR"

    # Initialize
    if [[ ! -d ".terraform" ]]; then
        log_info "Initializing DR Terraform..."
        terraform init -input=false
    fi

    # Plan and apply
    log_info "Planning DR infrastructure..."
    terraform plan -out=tfplan -input=false

    log_info "Creating DR infrastructure..."
    terraform apply -auto-approve tfplan
    rm -f tfplan

    log_success "DR region created"
}

# =============================================================================
# Wait for Services
# =============================================================================

wait_for_services() {
    log_step "Step 4/4: Waiting for services to be ready..."
    echo ""
    wait_for_instances
    echo ""
    wait_for_patroni
}

# =============================================================================
# Print Summary
# =============================================================================

print_summary() {
    cd "$TERRAFORM_DIR"

    # Get all outputs
    BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || echo "N/A")
    NLB_DNS=$(terraform output -raw nlb_dns_name 2>/dev/null || echo "N/A")
    MONITORING_IP=$(terraform output -raw monitoring_private_ip 2>/dev/null || echo "N/A")
    API_SERVER_IP=$(terraform output -raw api_server_private_ip 2>/dev/null || echo "N/A")

    echo ""
    echo "=========================================="
    echo -e "${GREEN} Infrastructure Created Successfully!${NC}"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Regions:${NC}"
    echo "  Primary: $PRIMARY_REGION"
    if [[ "$WITH_DR" == "true" ]]; then
        echo "  DR:      $DR_REGION"
    fi

    echo ""
    echo -e "${CYAN}PostgreSQL Access:${NC}"
    echo "  NLB DNS:     $NLB_DNS"
    echo "  R/W Port:    5432 (routes to leader)"
    echo "  R/O Port:    5433 (routes to replicas)"
    echo ""
    echo "  # Get password:"
    echo "  aws ssm get-parameter --name /pgha/postgres-password --with-decryption \\"
    echo "      --profile $PROFILE --region $PRIMARY_REGION --query 'Parameter.Value' --output text"
    echo ""
    echo "  # Connect (from bastion):"
    echo "  PGPASSWORD=\$(aws ssm get-parameter --name /pgha/postgres-password --with-decryption --query 'Parameter.Value' --output text)"
    echo "  psql -h $NLB_DNS -p 5432 -U postgres"

    echo ""
    echo -e "${CYAN}API Endpoints (via bastion SSH tunnel):${NC}"
    echo "  Python API:  http://$API_SERVER_IP:8000"
    echo "  Go API:      http://$API_SERVER_IP:8001"
    echo ""
    echo "  # Create SSH tunnel:"
    echo "  ssh -i \"\$SSH_KEY\" -L 8000:$API_SERVER_IP:8000 -L 8001:$API_SERVER_IP:8001 ec2-user@$BASTION_IP"
    echo "  # Then access: http://localhost:8000/health"

    echo ""
    echo -e "${CYAN}Monitoring (via bastion SSH tunnel):${NC}"
    echo "  Grafana:     http://$MONITORING_IP:3000  (admin/admin)"
    echo "  Prometheus:  http://$MONITORING_IP:9090"
    echo "  Alertmanager: http://$MONITORING_IP:9093"
    echo ""
    echo "  # Create SSH tunnel:"
    echo "  ssh -i \"\$SSH_KEY\" -L 3000:$MONITORING_IP:3000 -L 9090:$MONITORING_IP:9090 ec2-user@$BASTION_IP"
    echo "  # Then access: http://localhost:3000"

    echo ""
    echo -e "${CYAN}SSH Access:${NC}"
    echo "  Bastion IP:  $BASTION_IP"
    echo ""
    echo "  # Direct SSH to bastion:"
    echo "  ssh -i \"\$SSH_KEY\" ec2-user@$BASTION_IP"
    echo ""
    echo "  # SSM Session (no SSH key needed):"
    echo "  aws ssm start-session --target <instance-id> --profile $PROFILE"

    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. ./scripts/health-check.sh    # Verify cluster health"
    echo "  2. ./scripts/backup-full.sh     # Create first backup"
    echo "  3. ./scripts/chaos-test.sh      # Test failover"

    echo ""
    echo "=========================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "=========================================="
    echo " PostgreSQL HA/DR Cluster - CREATE"
    echo "=========================================="
    echo ""

    preflight_checks
    apply_primary
    build_and_push_apis
    apply_dr_region
    wait_for_services
    print_summary
}

main "$@"
