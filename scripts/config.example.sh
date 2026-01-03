#!/bin/bash
# =============================================================================
# Configuration for PostgreSQL HA/DR Scripts
# =============================================================================
# Single source of truth for all user-configurable values.
#
# SETUP:
#   1. Copy this file: cp config.example.sh config.sh
#   2. Edit config.sh with your values
#   3. Run ./setup.sh to validate your configuration
#
# NOTE: config.sh is gitignored - your settings won't be committed.
# =============================================================================

set -e

# =============================================================================
# USER CONFIGURATION - Edit these values in your config.sh
# =============================================================================

# AWS Profile (must exist in ~/.aws/credentials)
AWS_PROFILE="your-aws-profile"

# AWS Region
AWS_REGION="us-east-1"

# SSH Key Path (for bastion access)
# Windows Git Bash: /c/Users/yourname/path/to/key.pem
# Linux/Mac:        /home/yourname/.ssh/key.pem
SSH_KEY_PATH="/path/to/your-aws-key.pem"

# =============================================================================
# DERIVED VALUES - Auto-detected, do not edit
# =============================================================================

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
DR_TERRAFORM_DIR="$PROJECT_ROOT/terraform/dr-region"

# AWS Account ID (auto-detected from profile)
get_aws_account_id() {
    aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null || echo ""
}

# =============================================================================
# COLORS AND LOGGING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

# =============================================================================
# TERRAFORM OUTPUT HELPERS
# =============================================================================

get_terraform_output() {
    local output_name="$1"
    cd "$TERRAFORM_DIR"
    terraform output -raw "$output_name" 2>/dev/null || echo ""
}

get_terraform_output_json() {
    local output_name="$1"
    cd "$TERRAFORM_DIR"
    terraform output -json "$output_name" 2>/dev/null || echo "[]"
}

# Infrastructure values (from Terraform state)
get_nlb_dns()        { get_terraform_output "nlb_dns_name"; }
get_bastion_ip()     { get_terraform_output "bastion_public_ip"; }
get_monitoring_ip()  { get_terraform_output "monitoring_private_ip"; }
get_api_server_ip()  { get_terraform_output "api_server_private_ip"; }

get_ecr_python_url() { get_terraform_output "ecr_repository_python_url"; }
get_ecr_go_url()     { get_terraform_output "ecr_repository_go_url"; }

get_patroni_ips() {
    get_terraform_output_json "patroni_private_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true
}

get_etcd_ips() {
    get_terraform_output_json "etcd_private_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true
}

get_patroni_instance_ids() {
    get_terraform_output_json "patroni_instance_ids" | grep -oE 'i-[a-z0-9]+' || true
}

# =============================================================================
# SSH HELPERS
# =============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"

# Run SSH command via bastion to internal node
ssh_via_bastion() {
    local target_ip="$1"
    local command="$2"
    local bastion_ip=$(get_bastion_ip)

    ssh $SSH_OPTS \
        -o "ProxyCommand=ssh $SSH_OPTS -i \"$SSH_KEY_PATH\" -W %h:%p ec2-user@$bastion_ip" \
        -i "$SSH_KEY_PATH" \
        "ec2-user@$target_ip" "$command"
}

# Run SSH command directly to bastion
ssh_to_bastion() {
    local command="$1"
    local bastion_ip=$(get_bastion_ip)

    ssh $SSH_OPTS -i "$SSH_KEY_PATH" "ec2-user@$bastion_ip" "$command"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_config() {
    local errors=0

    # Check AWS Profile
    if [[ "$AWS_PROFILE" == "your-aws-profile" ]] || [[ -z "$AWS_PROFILE" ]]; then
        log_error "AWS_PROFILE not configured in config.sh"
        ((errors++))
    elif ! aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
        log_error "AWS_PROFILE '$AWS_PROFILE' is not valid or credentials expired"
        ((errors++))
    fi

    # Check SSH Key
    if [[ "$SSH_KEY_PATH" == "/path/to/your-aws-key.pem" ]] || [[ -z "$SSH_KEY_PATH" ]]; then
        log_error "SSH_KEY_PATH not configured in config.sh"
        ((errors++))
    elif [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_error "SSH key not found: $SSH_KEY_PATH"
        ((errors++))
    fi

    return $errors
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Only log if being sourced (not during setup validation)
if [[ "${PGHA_SILENT:-}" != "true" ]]; then
    log_info "Config loaded: $PROJECT_ROOT"
fi
