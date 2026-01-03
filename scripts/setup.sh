#!/bin/bash
# =============================================================================
# PostgreSQL HA/DR - Initial Setup and Validation
# =============================================================================
# Validates that all required configuration is in place before deployment.
#
# Usage: ./setup.sh
#
# This script checks:
#   1. Required tools (terraform, aws, docker)
#   2. Configuration files (config.sh, terraform.tfvars)
#   3. AWS credentials and permissions
#   4. SSH key accessibility
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA/DR - Setup Validation${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

ERRORS=0
WARNINGS=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; }
check_fail() { echo -e "  ${RED}✗${NC} $1"; ((ERRORS++)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; ((WARNINGS++)); }
check_info() { echo -e "  ${BLUE}i${NC} $1"; }

# =============================================================================
# 1. Check Required Tools
# =============================================================================

echo -e "${CYAN}1. Checking required tools...${NC}"

if command -v terraform &> /dev/null; then
    TF_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)
    check_pass "Terraform: $TF_VERSION"
else
    check_fail "Terraform not found. Install from: https://terraform.io/downloads"
fi

if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1)
    check_pass "AWS CLI: $AWS_VERSION"
else
    check_fail "AWS CLI not found. Install from: https://aws.amazon.com/cli/"
fi

if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
    check_pass "Docker: $DOCKER_VERSION"
else
    check_warn "Docker not found. Required for API builds (use --skip-api if not needed)"
fi

echo ""

# =============================================================================
# 2. Check Configuration Files
# =============================================================================

echo -e "${CYAN}2. Checking configuration files...${NC}"

# Check scripts/config.sh
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    check_pass "scripts/config.sh exists"

    # Source it silently to validate
    export PGHA_SILENT=true
    source "$SCRIPT_DIR/config.sh"
    unset PGHA_SILENT

    # Validate values
    if [[ "$AWS_PROFILE" == "your-aws-profile" ]] || [[ -z "$AWS_PROFILE" ]]; then
        check_fail "AWS_PROFILE not configured in config.sh"
    else
        check_pass "AWS_PROFILE: $AWS_PROFILE"
    fi

    if [[ "$SSH_KEY_PATH" == "/path/to/your-aws-key.pem" ]] || [[ -z "$SSH_KEY_PATH" ]]; then
        check_fail "SSH_KEY_PATH not configured in config.sh"
    elif [[ ! -f "$SSH_KEY_PATH" ]]; then
        check_fail "SSH key not found: $SSH_KEY_PATH"
    else
        check_pass "SSH_KEY_PATH: $SSH_KEY_PATH"
    fi
else
    check_fail "scripts/config.sh not found"
    check_info "Run: cp scripts/config.example.sh scripts/config.sh"
fi

# Check terraform/terraform.tfvars
if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    check_pass "terraform/terraform.tfvars exists"

    # Check for placeholder values
    if grep -q "YOUR_AWS_ACCOUNT_ID" "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null; then
        check_fail "terraform.tfvars has placeholder: YOUR_AWS_ACCOUNT_ID"
    fi

    if grep -q "your-key-pair-name" "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null; then
        check_fail "terraform.tfvars has placeholder: your-key-pair-name"
    fi
else
    check_fail "terraform/terraform.tfvars not found"
    check_info "Run: cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
fi

echo ""

# =============================================================================
# 3. Check AWS Credentials
# =============================================================================

echo -e "${CYAN}3. Checking AWS credentials...${NC}"

if [[ -n "$AWS_PROFILE" ]] && [[ "$AWS_PROFILE" != "your-aws-profile" ]]; then
    if aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
        ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text)
        check_pass "AWS credentials valid"
        check_info "Account: $ACCOUNT_ID"
        check_info "Identity: $USER_ARN"
    else
        check_fail "AWS credentials invalid or expired for profile: $AWS_PROFILE"
    fi
else
    check_warn "Skipping AWS check (AWS_PROFILE not configured)"
fi

echo ""

# =============================================================================
# 4. Check Terraform State
# =============================================================================

echo -e "${CYAN}4. Checking Terraform state...${NC}"

if [[ -d "$TERRAFORM_DIR/.terraform" ]]; then
    check_pass "Terraform initialized"

    if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]] || [[ -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]]; then
        check_pass "Terraform state exists"

        # Check if infrastructure is deployed
        cd "$TERRAFORM_DIR"
        RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l || echo "0")
        if [[ "$RESOURCE_COUNT" -gt "0" ]]; then
            check_info "Resources in state: $RESOURCE_COUNT"
        else
            check_info "No resources deployed yet"
        fi
    else
        check_info "No Terraform state (infrastructure not deployed)"
    fi
else
    check_info "Terraform not initialized (run: cd terraform && terraform init)"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================

echo -e "${BOLD}========================================${NC}"
if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Ready to deploy. Run:"
    echo "  ./scripts/create-cluster.sh"
elif [[ $ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}$WARNINGS warning(s), but ready to proceed.${NC}"
    echo ""
    echo "You can deploy with:"
    echo "  ./scripts/create-cluster.sh"
else
    echo -e "${RED}$ERRORS error(s) found. Please fix before deploying.${NC}"
    echo ""
    echo "Quick fix steps:"
    echo "  1. cp scripts/config.example.sh scripts/config.sh"
    echo "  2. Edit scripts/config.sh with your values"
    echo "  3. cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
    echo "  4. Edit terraform/terraform.tfvars with your values"
    echo "  5. Run ./scripts/setup.sh again"
fi
echo -e "${BOLD}========================================${NC}"
echo ""

exit $ERRORS
