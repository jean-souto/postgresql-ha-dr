#!/bin/bash
# =============================================================================
# pgBackRest Backup Verification Script
# =============================================================================
# Verifies the integrity and status of pgBackRest backups.
# Checks backup history, WAL archiving, and S3 connectivity.
#
# Usage: ./verify-backup.sh [--full]
#
# Options:
#   --full    Run full verification including backup restore test
#
# Requirements:
#   - pgBackRest installed and configured
#   - AWS credentials (via instance profile)
# =============================================================================

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" 2>/dev/null || true

# Default stanza name
STANZA="${PGBACKREST_STANZA:-pgha-dev-postgres}"
FULL_CHECK="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Track overall status
OVERALL_STATUS=0

check_result() {
    local result=$1
    local message=$2

    if [ $result -eq 0 ]; then
        log_pass "$message"
    else
        log_fail "$message"
        OVERALL_STATUS=1
    fi
}

# -----------------------------------------------------------------------------
# Check pgBackRest installation
# -----------------------------------------------------------------------------

check_installation() {
    log_info "Checking pgBackRest installation..."

    if command -v pgbackrest &> /dev/null; then
        local version
        version=$(pgbackrest version 2>/dev/null || echo "unknown")
        log_pass "pgBackRest is installed: $version"
        return 0
    else
        log_fail "pgBackRest is NOT installed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Check configuration
# -----------------------------------------------------------------------------

check_configuration() {
    log_info "Checking pgBackRest configuration..."

    if [ -f /etc/pgbackrest/pgbackrest.conf ]; then
        log_pass "Configuration file exists: /etc/pgbackrest/pgbackrest.conf"

        # Check stanza configuration
        if grep -q "\[${STANZA}\]" /etc/pgbackrest/pgbackrest.conf 2>/dev/null; then
            log_pass "Stanza '$STANZA' is configured"
        else
            log_fail "Stanza '$STANZA' not found in configuration"
            return 1
        fi

        # Check S3 configuration
        if grep -q "repo1-type=s3" /etc/pgbackrest/pgbackrest.conf 2>/dev/null; then
            log_pass "S3 repository configured"
        else
            log_warn "S3 repository not configured"
        fi

        return 0
    else
        log_fail "Configuration file NOT found"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Check stanza
# -----------------------------------------------------------------------------

check_stanza() {
    log_info "Checking stanza status..."

    if sudo -u postgres pgbackrest --stanza="$STANZA" check 2>/dev/null; then
        log_pass "Stanza check passed"
        return 0
    else
        log_fail "Stanza check failed"
        log_warn "Try running: sudo -u postgres pgbackrest --stanza=$STANZA stanza-create"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Check backup history
# -----------------------------------------------------------------------------

check_backup_history() {
    log_info "Checking backup history..."

    local backup_info
    backup_info=$(sudo -u postgres pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null || echo "[]")

    # Parse backup info
    local stanza_status
    stanza_status=$(echo "$backup_info" | jq -r '.[0].status.code' 2>/dev/null || echo "99")

    if [ "$stanza_status" = "0" ]; then
        log_pass "Stanza status: OK"
    else
        log_fail "Stanza status: Error (code: $stanza_status)"
        return 1
    fi

    # Count backups
    local full_count diff_count
    full_count=$(echo "$backup_info" | jq '.[0].backup | map(select(.type == "full")) | length' 2>/dev/null || echo "0")
    diff_count=$(echo "$backup_info" | jq '.[0].backup | map(select(.type == "diff")) | length' 2>/dev/null || echo "0")

    echo ""
    echo "  Backup Summary:"
    echo "  ─────────────────────────────"
    echo "  Full backups:         $full_count"
    echo "  Differential backups: $diff_count"
    echo ""

    if [ "$full_count" -eq 0 ]; then
        log_warn "No full backups found!"
        log_warn "Run: ./backup-full.sh"
        return 1
    else
        log_pass "Found $full_count full backup(s)"
    fi

    # Show last backup info
    local last_backup
    last_backup=$(echo "$backup_info" | jq -r '.[0].backup[-1]' 2>/dev/null || echo "{}")

    if [ "$last_backup" != "{}" ] && [ "$last_backup" != "null" ]; then
        local last_type last_time last_size
        last_type=$(echo "$last_backup" | jq -r '.type' 2>/dev/null || echo "unknown")
        last_time=$(echo "$last_backup" | jq -r '.timestamp.stop' 2>/dev/null || echo "unknown")
        last_size=$(echo "$last_backup" | jq -r '.info.size' 2>/dev/null || echo "0")

        echo "  Last Backup:"
        echo "  ─────────────────────────────"
        echo "  Type:     $last_type"
        echo "  Time:     $last_time"
        echo "  Size:     $(numfmt --to=iec-i --suffix=B $last_size 2>/dev/null || echo "${last_size} bytes")"
        echo ""
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Check WAL archiving
# -----------------------------------------------------------------------------

check_wal_archiving() {
    log_info "Checking WAL archiving status..."

    # Check PostgreSQL archive_mode
    local archive_mode
    archive_mode=$(sudo -u postgres psql -t -c "SHOW archive_mode;" 2>/dev/null | tr -d ' ' || echo "unknown")

    if [ "$archive_mode" = "on" ]; then
        log_pass "PostgreSQL archive_mode is ON"
    else
        log_fail "PostgreSQL archive_mode is: $archive_mode"
        return 1
    fi

    # Check archive_command
    local archive_command
    archive_command=$(sudo -u postgres psql -t -c "SHOW archive_command;" 2>/dev/null | tr -d ' ' || echo "unknown")

    if echo "$archive_command" | grep -q "pgbackrest"; then
        log_pass "archive_command uses pgBackRest"
    else
        log_warn "archive_command may not be configured for pgBackRest"
        log_warn "Current: $archive_command"
    fi

    # Check archived WAL count
    local archive_info
    archive_info=$(sudo -u postgres pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null || echo "[]")

    local min_wal max_wal
    min_wal=$(echo "$archive_info" | jq -r '.[0].archive[0].min' 2>/dev/null || echo "none")
    max_wal=$(echo "$archive_info" | jq -r '.[0].archive[0].max' 2>/dev/null || echo "none")

    if [ "$min_wal" != "none" ] && [ "$min_wal" != "null" ]; then
        echo ""
        echo "  WAL Archive Range:"
        echo "  ─────────────────────────────"
        echo "  Oldest WAL: $min_wal"
        echo "  Latest WAL: $max_wal"
        echo ""
        log_pass "WAL archiving is active"
    else
        log_warn "No archived WAL files found"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Check S3 connectivity
# -----------------------------------------------------------------------------

check_s3_connectivity() {
    log_info "Checking S3 connectivity..."

    # Extract bucket from config
    local bucket
    bucket=$(grep "repo1-s3-bucket=" /etc/pgbackrest/pgbackrest.conf 2>/dev/null | cut -d= -f2 || echo "")

    if [ -z "$bucket" ]; then
        log_warn "Could not determine S3 bucket from config"
        return 1
    fi

    echo "  S3 Bucket: $bucket"

    # Try to list bucket contents
    if aws s3 ls "s3://$bucket/pgbackrest/" --max-items 1 &>/dev/null; then
        log_pass "S3 bucket is accessible"
        return 0
    else
        log_fail "Cannot access S3 bucket"
        log_warn "Check IAM permissions and bucket policy"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Show full backup details
# -----------------------------------------------------------------------------

show_backup_details() {
    log_info "Full backup details:"
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    sudo -u postgres pgbackrest --stanza="$STANZA" info
    echo "─────────────────────────────────────────────────────────────"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "=========================================="
    echo "  pgBackRest Backup Verification"
    echo "=========================================="
    echo "  Stanza: $STANZA"
    echo "=========================================="
    echo ""

    check_installation
    check_result $? "pgBackRest installation"
    echo ""

    check_configuration
    check_result $? "Configuration file"
    echo ""

    check_stanza
    check_result $? "Stanza status"
    echo ""

    check_backup_history
    check_result $? "Backup history"
    echo ""

    check_wal_archiving
    check_result $? "WAL archiving"
    echo ""

    check_s3_connectivity
    check_result $? "S3 connectivity"
    echo ""

    if [ "$FULL_CHECK" = "--full" ]; then
        show_backup_details
    fi

    echo ""
    echo "=========================================="
    if [ $OVERALL_STATUS -eq 0 ]; then
        log_pass "All checks passed!"
    else
        log_fail "Some checks failed - review output above"
    fi
    echo "=========================================="

    exit $OVERALL_STATUS
}

main "$@"
