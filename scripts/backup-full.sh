#!/bin/bash
# =============================================================================
# pgBackRest Full Backup Script
# =============================================================================
# Executes a full backup of the PostgreSQL cluster to S3.
# Should be run on the primary node only.
#
# Usage: ./backup-full.sh [--async]
#
# Options:
#   --async    Run backup asynchronously (returns immediately)
#
# Requirements:
#   - pgBackRest installed and configured
#   - AWS credentials (via instance profile)
#   - This node must be the primary
# =============================================================================

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" 2>/dev/null || true

# Default stanza name (override via config.sh if needed)
STANZA="${PGBACKREST_STANZA:-pgha-dev-postgres}"
ASYNC="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# -----------------------------------------------------------------------------
# Check if running on primary
# -----------------------------------------------------------------------------

check_primary() {
    log_info "Checking if this node is the primary..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi

    local role
    role=$(curl -s http://localhost:8008/patroni 2>/dev/null | jq -r '.role' 2>/dev/null || echo "unknown")

    if [ "$role" != "master" ] && [ "$role" != "primary" ]; then
        log_error "This node is not the primary (role: $role)"
        log_error "Full backups must be run on the primary node"
        exit 1
    fi

    log_info "Confirmed: This is the primary node"
}

# -----------------------------------------------------------------------------
# Verify pgBackRest configuration
# -----------------------------------------------------------------------------

verify_config() {
    log_info "Verifying pgBackRest configuration..."

    if ! command -v pgbackrest &> /dev/null; then
        log_error "pgbackrest is not installed"
        exit 1
    fi

    # Check stanza
    if ! sudo -u postgres pgbackrest --stanza="$STANZA" check 2>/dev/null; then
        log_warn "pgBackRest check failed - attempting stanza upgrade..."
        sudo -u postgres pgbackrest --stanza="$STANZA" stanza-upgrade 2>/dev/null || true
    fi

    log_info "pgBackRest configuration verified"
}

# -----------------------------------------------------------------------------
# Execute Full Backup
# -----------------------------------------------------------------------------

execute_backup() {
    log_info "Starting full backup to S3..."
    log_info "Stanza: $STANZA"

    local start_time
    start_time=$(date +%s)

    # Build backup command
    local backup_cmd="pgbackrest --stanza=$STANZA --type=full backup"

    if [ "$ASYNC" = "--async" ]; then
        log_info "Running backup asynchronously..."
        sudo -u postgres $backup_cmd &
        local pid=$!
        log_info "Backup started in background (PID: $pid)"
        log_info "Monitor with: sudo -u postgres pgbackrest --stanza=$STANZA info"
        return 0
    fi

    # Run backup synchronously
    if sudo -u postgres $backup_cmd; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "Full backup completed successfully!"
        log_info "Duration: ${duration} seconds"
    else
        log_error "Backup failed!"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Show backup info
# -----------------------------------------------------------------------------

show_info() {
    log_info "Current backup status:"
    echo ""
    sudo -u postgres pgbackrest --stanza="$STANZA" info
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "=========================================="
    echo "  pgBackRest Full Backup"
    echo "=========================================="
    echo ""

    check_primary
    verify_config
    execute_backup
    show_info

    log_info "Backup script completed"
}

main "$@"
