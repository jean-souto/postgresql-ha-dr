#!/bin/bash
# =============================================================================
# Destroy PostgreSQL HA Cluster - Complete Cleanup
# =============================================================================
# Destroys ALL infrastructure including:
#   - DR region (us-west-2)
#   - Primary region (us-east-1)
#   - ECR repositories (force delete with images)
#   - S3 buckets (empty versioned objects)
#   - SSM Parameters
#   - Any orphaned resources
#
# Usage:
#   ./destroy-cluster.sh              # Interactive (asks confirmation)
#   ./destroy-cluster.sh --force      # Skip confirmation
#
# Requirements:
#   - Terraform installed and in PATH
#   - AWS CLI installed and configured
# =============================================================================

set -e

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
DR_TERRAFORM_DIR="$PROJECT_ROOT/terraform/dr-region"

# Source shared config (provides AWS_PROFILE, AWS_REGION, colors, helpers)
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    export PGHA_SILENT=true
    source "$SCRIPT_DIR/config.sh"
    unset PGHA_SILENT
else
    # Fallback if config.sh doesn't exist
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
    AWS_PROFILE="postgresql-ha-profile"
    AWS_REGION="us-east-1"
fi

# Region configuration
PRIMARY_REGION="${AWS_REGION:-us-east-1}"
DR_REGION="us-west-2"
PROFILE="$AWS_PROFILE"

# Parse arguments
FORCE=false
for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Options:"
            echo "  --force, -f  Skip confirmation prompt"
            exit 0
            ;;
    esac
done

echo ""
echo "=========================================="
echo " PostgreSQL HA/DR Cluster - FULL DESTROY"
echo "=========================================="
echo ""

# Confirmation
if [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}WARNING: This will DESTROY all infrastructure!${NC}"
    echo -e "${RED}Both regions ($PRIMARY_REGION + $DR_REGION) will be affected!${NC}"
    echo -e "${RED}All data will be permanently lost!${NC}"
    echo ""
    read -p "Type 'destroy' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "destroy" ]]; then
        log_warn "Aborted. No changes made."
        exit 1
    fi
fi

START_TIME=$(date +%s)

# Get AWS Account ID
ACCOUNT_ID=$(aws --profile $PROFILE sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
log_info "AWS Account: $ACCOUNT_ID"
log_info "AWS Profile: $PROFILE"

# =============================================================================
# Helper: Initialize Terraform with upgrade if needed
# =============================================================================
terraform_init_safe() {
    local dir="$1"
    cd "$dir"

    if [[ ! -d ".terraform" ]]; then
        terraform init -input=false > /dev/null 2>&1
        return $?
    fi

    # Try normal init first, if fails try with upgrade (lock file issues)
    if ! terraform init -input=false > /dev/null 2>&1; then
        log_info "  Lock file inconsistent, running init -upgrade..."
        terraform init -upgrade -input=false > /dev/null 2>&1
    fi
}

# =============================================================================
# Step 1: Destroy DR Region (must be first - depends on primary)
# =============================================================================
log_info "Step 1/7: Destroying DR Region ($DR_REGION)..."
if [[ -d "$DR_TERRAFORM_DIR" ]]; then
    if terraform_init_safe "$DR_TERRAFORM_DIR"; then
        if terraform state list 2>/dev/null | grep -q .; then
            terraform destroy -auto-approve 2>&1 || log_warn "DR region destroy had warnings"
            log_success "DR region destroyed"
        else
            log_info "DR region already empty"
        fi
    fi
else
    log_info "DR region terraform not found, skipping"
fi

# =============================================================================
# Step 2: Force delete ECR repositories (they contain images)
# =============================================================================
log_info "Step 2/7: Force deleting ECR repositories..."
for repo in pgha-dev-api-python pgha-dev-api-go; do
    if aws --profile $PROFILE ecr describe-repositories --repository-names "$repo" --region $PRIMARY_REGION 2>/dev/null > /dev/null; then
        log_info "  Deleting ECR: $repo"
        aws --profile $PROFILE ecr delete-repository --repository-name "$repo" --force --region $PRIMARY_REGION 2>/dev/null || true
    fi
done
log_success "ECR repositories cleaned"

# =============================================================================
# Step 3: Empty and delete S3 buckets (handle versioned objects efficiently)
# =============================================================================
log_info "Step 3/7: Emptying S3 buckets..."

# Function to efficiently delete all objects from a versioned bucket using Python
empty_versioned_bucket() {
    local bucket=$1
    local profile=$2

    log_info "  Emptying bucket: $bucket (batch delete)..."

    # Use Python for efficient batch deletion - handles pagination and batching
    # Uses temp file to avoid Windows command line length limits
    python3 << PYEOF
import subprocess
import json
import tempfile
import os

bucket = "$bucket"
profile = "$profile"

def run_aws(args):
    cmd = ["aws", "--profile", profile] + args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        return json.loads(result.stdout)
    return None

def delete_batch(bucket, objects):
    if not objects:
        return 0
    delete_struct = {"Objects": objects, "Quiet": True}

    # Write to temp file to avoid Windows command line length limits
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(delete_struct, f)
        temp_path = f.name

    try:
        cmd = ["aws", "--profile", profile, "s3api", "delete-objects",
               "--bucket", bucket, "--delete", f"file://{temp_path}"]
        subprocess.run(cmd, capture_output=True)
    finally:
        os.unlink(temp_path)

    return len(objects)

total_deleted = 0
key_marker = ""
version_marker = ""

while True:
    # Build command with pagination markers
    cmd = ["s3api", "list-object-versions", "--bucket", bucket, "--max-keys", "1000"]
    if key_marker:
        cmd.extend(["--key-marker", key_marker])
    if version_marker:
        cmd.extend(["--version-id-marker", version_marker])

    data = run_aws(cmd)
    if not data:
        break

    # Collect objects to delete
    to_delete = []
    for v in data.get("Versions", []):
        to_delete.append({"Key": v["Key"], "VersionId": v["VersionId"]})
    for d in data.get("DeleteMarkers", []):
        to_delete.append({"Key": d["Key"], "VersionId": d["VersionId"]})

    if to_delete:
        deleted = delete_batch(bucket, to_delete)
        total_deleted += deleted
        print(f"    Deleted {total_deleted} objects so far...", flush=True)

    # Check if there are more pages
    if data.get("IsTruncated"):
        key_marker = data.get("NextKeyMarker", "")
        version_marker = data.get("NextVersionIdMarker", "")
    else:
        break

print(f"  Total deleted from {bucket}: {total_deleted} objects")
PYEOF
}

for bucket in "pgha-dev-pgbackrest-${ACCOUNT_ID}" "pgha-dev-dr-pgbackrest-${ACCOUNT_ID}" "pgha-terraform-state-${ACCOUNT_ID}"; do
    if aws --profile $PROFILE s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        empty_versioned_bucket "$bucket" "$PROFILE"
    fi
done
log_success "S3 buckets cleaned"

# =============================================================================
# Step 4: Delete SSM Parameters
# =============================================================================
log_info "Step 4/7: Deleting SSM Parameters..."
for region in $PRIMARY_REGION $DR_REGION; do
    params=$(aws --profile $PROFILE ssm describe-parameters --region $region \
        --query "Parameters[?contains(Name,'pgha')].Name" --output text 2>/dev/null || echo "")
    for param in $params; do
        [[ -n "$param" ]] && {
            log_info "  Deleting: $param ($region)"
            aws --profile $PROFILE ssm delete-parameter --name "$param" --region $region 2>/dev/null || true
        }
    done
done
log_success "SSM Parameters cleaned"

# =============================================================================
# Step 5: Destroy Primary Region via Terraform
# =============================================================================
log_info "Step 5/7: Destroying Primary Region ($PRIMARY_REGION)..."
if terraform_init_safe "$TERRAFORM_DIR"; then
    if terraform state list 2>/dev/null | grep -q .; then
        terraform destroy -auto-approve 2>&1 || log_warn "Primary region destroy had warnings"
        log_success "Primary region destroyed"
    else
        log_info "Primary region already empty"
    fi
fi

# =============================================================================
# Step 6: Cleanup orphaned resources (safety net)
# =============================================================================
log_info "Step 6/7: Checking for orphaned resources..."

# Terminate any orphaned EC2 instances (by Name tag pattern)
for region in $PRIMARY_REGION $DR_REGION; do
    instances=$(aws --profile $PROFILE ec2 describe-instances --region $region \
        --filters "Name=tag:Name,Values=pgha-*" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || echo "")
    for instance in $instances; do
        [[ -n "$instance" ]] && {
            log_warn "  Terminating orphaned instance: $instance ($region)"
            aws --profile $PROFILE ec2 terminate-instances --instance-ids "$instance" --region $region 2>/dev/null || true
        }
    done
done

# Wait for instances to terminate
log_info "  Waiting for instances to terminate..."
sleep 10

# Delete orphaned Target Groups (must be before NLBs in some cases, but after instances)
for region in $PRIMARY_REGION $DR_REGION; do
    tgs=$(aws --profile $PROFILE elbv2 describe-target-groups --region $region \
        --query "TargetGroups[?contains(TargetGroupName,'pgha')].TargetGroupArn" --output text 2>/dev/null || echo "")
    for tg in $tgs; do
        [[ -n "$tg" ]] && {
            log_warn "  Deleting orphaned target group: $tg"
            aws --profile $PROFILE elbv2 delete-target-group --target-group-arn "$tg" --region $region 2>/dev/null || true
        }
    done
done

# Delete orphaned NLBs
for region in $PRIMARY_REGION $DR_REGION; do
    nlbs=$(aws --profile $PROFILE elbv2 describe-load-balancers --region $region \
        --query "LoadBalancers[?contains(LoadBalancerName,'pgha')].LoadBalancerArn" --output text 2>/dev/null || echo "")
    for nlb in $nlbs; do
        [[ -n "$nlb" ]] && {
            log_warn "  Deleting orphaned NLB: $nlb"
            aws --profile $PROFILE elbv2 delete-load-balancer --load-balancer-arn "$nlb" --region $region 2>/dev/null || true
        }
    done
done

# Delete orphaned Elastic IPs
for region in $PRIMARY_REGION $DR_REGION; do
    # Get unassociated EIPs with pgha tag or all unassociated if we can't filter by tag
    eips=$(aws --profile $PROFILE ec2 describe-addresses --region $region \
        --query "Addresses[?AssociationId==null].AllocationId" --output text 2>/dev/null || echo "")
    for eip in $eips; do
        [[ -n "$eip" ]] && {
            # Check if it has pgha tag before deleting
            tags=$(aws --profile $PROFILE ec2 describe-tags --region $region \
                --filters "Name=resource-id,Values=$eip" "Name=key,Values=Name" \
                --query "Tags[0].Value" --output text 2>/dev/null || echo "")
            if [[ "$tags" == *pgha* ]] || [[ -z "$tags" ]]; then
                log_warn "  Releasing orphaned Elastic IP: $eip ($region)"
                aws --profile $PROFILE ec2 release-address --allocation-id "$eip" --region $region 2>/dev/null || true
            fi
        }
    done
done

# Delete orphaned SNS Topics
for region in $PRIMARY_REGION $DR_REGION; do
    topics=$(aws --profile $PROFILE sns list-topics --region $region \
        --query "Topics[?contains(TopicArn,'pgha')].TopicArn" --output text 2>/dev/null || echo "")
    for topic in $topics; do
        [[ -n "$topic" ]] && {
            log_warn "  Deleting orphaned SNS topic: $topic"
            aws --profile $PROFILE sns delete-topic --topic-arn "$topic" --region $region 2>/dev/null || true
        }
    done
done

# Delete orphaned security groups (by GroupName pattern, not tag)
for region in $PRIMARY_REGION $DR_REGION; do
    sgs=$(aws --profile $PROFILE ec2 describe-security-groups --region $region \
        --query "SecurityGroups[?starts_with(GroupName,'pgha-')].GroupId" --output text 2>/dev/null || echo "")
    for sg in $sgs; do
        [[ -n "$sg" ]] && {
            log_warn "  Deleting orphaned security group: $sg ($region)"
            aws --profile $PROFILE ec2 delete-security-group --group-id "$sg" --region $region 2>/dev/null || true
        }
    done
done

# Delete orphaned VPCs (must clean dependencies first)
for region in $PRIMARY_REGION $DR_REGION; do
    vpcs=$(aws --profile $PROFILE ec2 describe-vpcs --region $region \
        --filters "Name=tag:Name,Values=pgha-*" \
        --query "Vpcs[].VpcId" --output text 2>/dev/null || echo "")
    for vpc in $vpcs; do
        [[ -n "$vpc" ]] && {
            log_warn "  Cleaning orphaned VPC: $vpc ($region)"

            # Delete non-main route tables first
            rts=$(aws --profile $PROFILE ec2 describe-route-tables --region $region \
                --filters "Name=vpc-id,Values=$vpc" \
                --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null || echo "")
            for rt in $rts; do
                # Disassociate first
                assocs=$(aws --profile $PROFILE ec2 describe-route-tables --region $region \
                    --route-table-ids "$rt" \
                    --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text 2>/dev/null || echo "")
                for assoc in $assocs; do
                    aws --profile $PROFILE ec2 disassociate-route-table --association-id "$assoc" --region $region 2>/dev/null || true
                done
                aws --profile $PROFILE ec2 delete-route-table --route-table-id "$rt" --region $region 2>/dev/null || true
            done

            # Delete subnets
            subnets=$(aws --profile $PROFILE ec2 describe-subnets --region $region \
                --filters "Name=vpc-id,Values=$vpc" --query "Subnets[].SubnetId" --output text 2>/dev/null || echo "")
            for subnet in $subnets; do
                aws --profile $PROFILE ec2 delete-subnet --subnet-id "$subnet" --region $region 2>/dev/null || true
            done

            # Delete internet gateway
            igws=$(aws --profile $PROFILE ec2 describe-internet-gateways --region $region \
                --filters "Name=attachment.vpc-id,Values=$vpc" --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || echo "")
            for igw in $igws; do
                aws --profile $PROFILE ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region $region 2>/dev/null || true
                aws --profile $PROFILE ec2 delete-internet-gateway --internet-gateway-id "$igw" --region $region 2>/dev/null || true
            done

            # Delete security groups in VPC (non-default)
            sgs=$(aws --profile $PROFILE ec2 describe-security-groups --region $region \
                --filters "Name=vpc-id,Values=$vpc" \
                --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo "")
            for sg in $sgs; do
                aws --profile $PROFILE ec2 delete-security-group --group-id "$sg" --region $region 2>/dev/null || true
            done

            # Delete VPC
            aws --profile $PROFILE ec2 delete-vpc --vpc-id "$vpc" --region $region 2>/dev/null || true
        }
    done
done

# Delete orphaned IAM Instance Profiles
profiles=$(aws --profile $PROFILE iam list-instance-profiles \
    --query "InstanceProfiles[?contains(InstanceProfileName,'pgha')].InstanceProfileName" --output text 2>/dev/null || echo "")
for profile in $profiles; do
    [[ -n "$profile" ]] && {
        log_warn "  Deleting orphaned instance profile: $profile"
        # Remove role from profile first
        roles=$(aws --profile $PROFILE iam get-instance-profile --instance-profile-name "$profile" \
            --query "InstanceProfile.Roles[].RoleName" --output text 2>/dev/null || echo "")
        for role in $roles; do
            aws --profile $PROFILE iam remove-role-from-instance-profile \
                --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
        done
        aws --profile $PROFILE iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
    }
done

# Delete orphaned IAM Roles (must detach policies first)
roles=$(aws --profile $PROFILE iam list-roles \
    --query "Roles[?contains(RoleName,'pgha')].RoleName" --output text 2>/dev/null || echo "")
for role in $roles; do
    [[ -n "$role" ]] && {
        log_warn "  Deleting orphaned IAM role: $role"
        # Detach managed policies
        policies=$(aws --profile $PROFILE iam list-attached-role-policies --role-name "$role" \
            --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || echo "")
        for policy in $policies; do
            aws --profile $PROFILE iam detach-role-policy --role-name "$role" --policy-arn "$policy" 2>/dev/null || true
        done
        # Delete inline policies
        inline=$(aws --profile $PROFILE iam list-role-policies --role-name "$role" \
            --query "PolicyNames[]" --output text 2>/dev/null || echo "")
        for pol in $inline; do
            aws --profile $PROFILE iam delete-role-policy --role-name "$role" --policy-name "$pol" 2>/dev/null || true
        done
        aws --profile $PROFILE iam delete-role --role-name "$role" 2>/dev/null || true
    }
done

# Delete S3 buckets (after emptying in step 3)
log_info "  Deleting S3 buckets..."
for bucket in "pgha-dev-pgbackrest-${ACCOUNT_ID}" "pgha-dev-dr-pgbackrest-${ACCOUNT_ID}" "pgha-terraform-state-${ACCOUNT_ID}"; do
    if aws --profile $PROFILE s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        log_warn "  Deleting bucket: $bucket"
        aws --profile $PROFILE s3 rb "s3://$bucket" --force 2>/dev/null || true
    fi
done

log_success "Orphan cleanup complete"

# =============================================================================
# Step 7: Verification
# =============================================================================
echo ""
echo "=========================================="
echo " Verification"
echo "=========================================="

verify() {
    local desc=$1
    local count=$2
    if [[ "$count" == "0" || -z "$count" ]]; then
        echo -e "  ${GREEN}✓${NC} $desc"
    else
        echo -e "  ${RED}✗${NC} $desc ($count remaining)"
    fi
}

# Check resources by Name tag pattern (matches how resources are created)
ec2_east=$(aws --profile $PROFILE ec2 describe-instances --region $PRIMARY_REGION \
    --filters "Name=tag:Name,Values=pgha-*" "Name=instance-state-name,Values=running,stopped" \
    --query "length(Reservations[].Instances[])" --output text 2>/dev/null || echo "0")
ec2_west=$(aws --profile $PROFILE ec2 describe-instances --region $DR_REGION \
    --filters "Name=tag:Name,Values=pgha-*" "Name=instance-state-name,Values=running,stopped" \
    --query "length(Reservations[].Instances[])" --output text 2>/dev/null || echo "0")
vpc_east=$(aws --profile $PROFILE ec2 describe-vpcs --region $PRIMARY_REGION \
    --filters "Name=tag:Name,Values=pgha-*" \
    --query "length(Vpcs[])" --output text 2>/dev/null || echo "0")
vpc_west=$(aws --profile $PROFILE ec2 describe-vpcs --region $DR_REGION \
    --filters "Name=tag:Name,Values=pgha-*" \
    --query "length(Vpcs[])" --output text 2>/dev/null || echo "0")
sg_east=$(aws --profile $PROFILE ec2 describe-security-groups --region $PRIMARY_REGION \
    --query "length(SecurityGroups[?starts_with(GroupName,'pgha-')])" --output text 2>/dev/null || echo "0")
tg_count=$(aws --profile $PROFILE elbv2 describe-target-groups --region $PRIMARY_REGION \
    --query "length(TargetGroups[?contains(TargetGroupName,'pgha')])" --output text 2>/dev/null || echo "0")
ecr_count=$(aws --profile $PROFILE ecr describe-repositories --region $PRIMARY_REGION \
    --query "length(repositories[?contains(repositoryName,'pgha')])" --output text 2>/dev/null || echo "0")
s3_count=$(aws --profile $PROFILE s3 ls 2>/dev/null | grep -c pgha || echo "0")
iam_roles=$(aws --profile $PROFILE iam list-roles \
    --query "length(Roles[?contains(RoleName,'pgha')])" --output text 2>/dev/null || echo "0")
iam_profiles=$(aws --profile $PROFILE iam list-instance-profiles \
    --query "length(InstanceProfiles[?contains(InstanceProfileName,'pgha')])" --output text 2>/dev/null || echo "0")
ssm_params=$(aws --profile $PROFILE ssm describe-parameters --region $PRIMARY_REGION \
    --query "length(Parameters[?contains(Name,'pgha')])" --output text 2>/dev/null || echo "0")
sns_topics=$(aws --profile $PROFILE sns list-topics --region $PRIMARY_REGION \
    --query "length(Topics[?contains(TopicArn,'pgha')])" --output text 2>/dev/null || echo "0")

verify "EC2 us-east-1" "$ec2_east"
verify "EC2 us-west-2" "$ec2_west"
verify "VPC us-east-1" "$vpc_east"
verify "VPC us-west-2" "$vpc_west"
verify "Security Groups" "$sg_east"
verify "Target Groups" "$tg_count"
verify "ECR repos" "$ecr_count"
verify "S3 buckets" "$s3_count"
verify "IAM Roles" "$iam_roles"
verify "Instance Profiles" "$iam_profiles"
verify "SSM Parameters" "$ssm_params"
verify "SNS Topics" "$sns_topics"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=========================================="
log_success "Full destruction completed in ${DURATION}s"
echo "=========================================="
echo ""
echo "To recreate: ./scripts/create-cluster.sh"
echo ""
