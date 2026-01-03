#!/bin/bash
# =============================================================================
# pgBackRest Incremental (Differential) Backup Script
# =============================================================================
# Executes a differential backup of the PostgreSQL cluster to S3.
# Differential backups only backup changes since the last full backup.
# Should be run on the primary node only.
#
# Usage: ./backup-incr.sh [--async]
#
# Options:
#   --async    Run backup asynchronously (returns immediately)
#
# Requirements:
#   - pgBackRest installed and configured
#   - At least one full backup must exist
#   - This node must be the primary
# =============================================================================

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" 2>/dev/null || true

# Default stanza name
STANZA="${PGBACKREST_STANZA:-pgha-dev-postgres}"
ASYNC="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# -----------------------------------------------------------------------------
# Check if running on primary
# -----------------------------------------------------------------------------

check_primary() {
    log_info "Checking if this node is the primary..."

    local role
    role=$(curl -s http://localhost:8008/patroni 2>/dev/null | jq -r '.role' 2>/dev/null || echo "unknown")

    if [ "$role" != "master" ] && [ "$role" != "primary" ]; then
        log_error "This node is not the primary (role: $role)"
        exit 1
    fi

    log_info "Confirmed: This is the primary node"
}

# -----------------------------------------------------------------------------
# Check for existing full backup
# -----------------------------------------------------------------------------

check_full_backup() {
    log_info "Checking for existing full backup..."

    local backup_info
    backup_info=$(sudo -u postgres pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null || echo "[]")

    local full_count
    full_count=$(echo "$backup_info" | jq '.[0].backup | map(select(.type == "full")) | length' 2>/dev/null || echo "0")

    if [ "$full_count" -eq 0 ]; then
        log_warn "No full backup found - running full backup instead of differential"
        log_info "Running: ./backup-full.sh"
        exec "$SCRIPT_DIR/backup-full.sh" "$ASYNC"
    fi

    log_info "Found $full_count full backup(s)"
}

# -----------------------------------------------------------------------------
# Execute Differential Backup
# -----------------------------------------------------------------------------

execute_backup() {
    log_info "Starting differential backup to S3..."
    log_info "Stanza: $STANZA"

    local start_time
    start_time=$(date +%s)

    local backup_cmd="pgbackrest --stanza=$STANZA --type=diff backup"

    if [ "$ASYNC" = "--async" ]; then
        log_info "Running backup asynchronously..."
        sudo -u postgres $backup_cmd &
        local pid=$!
        log_info "Backup started in background (PID: $pid)"
        return 0
    fi

    if sudo -u postgres $backup_cmd; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "Differential backup completed successfully!"
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
    echo "  pgBackRest Differential Backup"
    echo "=========================================="
    echo ""

    check_primary
    check_full_backup
    execute_backup
    show_info

    log_info "Backup script completed"
}

main "$@"
