#!/bin/bash
# =============================================================================
# pgBackRest Point-in-Time Recovery (PITR) Script
# =============================================================================
# Restores the PostgreSQL cluster to a specific point in time.
#
# CRITICAL: This script will STOP PostgreSQL and DESTROY existing data!
#           Only run this if you understand the implications.
#
# Usage: ./restore-pitr.sh <target_time>
#
# Examples:
#   ./restore-pitr.sh "2025-01-15 14:30:00"
#   ./restore-pitr.sh "2025-01-15 14:30:00+00"
#
# Requirements:
#   - pgBackRest installed and configured
#   - Valid backup exists in S3
#   - WAL archive files available for target time
#
# WARNING: This is a DESTRUCTIVE operation!
# =============================================================================

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" 2>/dev/null || true

# Default stanza name
STANZA="${PGBACKREST_STANZA:-pgha-dev-postgres}"
TARGET_TIME="${1:-}"
DATA_DIR="${PGDATA:-/var/lib/pgsql/17/data}"

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

log_critical() {
    echo -e "${RED}[CRITICAL]${NC} $1"
}

# -----------------------------------------------------------------------------
# Validate input
# -----------------------------------------------------------------------------

validate_input() {
    if [ -z "$TARGET_TIME" ]; then
        log_error "Target time not specified!"
        echo ""
        echo "Usage: $0 <target_time>"
        echo ""
        echo "Examples:"
        echo "  $0 \"2025-01-15 14:30:00\""
        echo "  $0 \"2025-01-15 14:30:00+00\""
        echo ""
        exit 1
    fi

    log_info "Target recovery time: $TARGET_TIME"
}

# -----------------------------------------------------------------------------
# Show available backups
# -----------------------------------------------------------------------------

show_available_backups() {
    log_info "Available backups:"
    echo ""
    sudo -u postgres pgbackrest --stanza="$STANZA" info || {
        log_error "No backups found!"
        exit 1
    }
    echo ""
}

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------

confirm_restore() {
    echo ""
    log_critical "=========================================="
    log_critical "  WARNING: DESTRUCTIVE OPERATION!"
    log_critical "=========================================="
    echo ""
    echo "This will:"
    echo "  1. STOP Patroni and PostgreSQL"
    echo "  2. DELETE all data in $DATA_DIR"
    echo "  3. RESTORE from backup to: $TARGET_TIME"
    echo "  4. RESTART services"
    echo ""
    echo "All data after $TARGET_TIME will be LOST!"
    echo ""
    read -p "Are you SURE you want to continue? (type 'YES' to confirm): " confirmation

    if [ "$confirmation" != "YES" ]; then
        log_info "Restore cancelled by user"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Stop services
# -----------------------------------------------------------------------------

stop_services() {
    log_info "Stopping Patroni..."
    sudo systemctl stop patroni || log_warn "Patroni may already be stopped"

    log_info "Stopping PostgreSQL (if running separately)..."
    sudo systemctl stop postgresql-17 2>/dev/null || true

    # Wait for services to stop
    sleep 5

    # Verify PostgreSQL is stopped
    if pgrep -x postgres > /dev/null; then
        log_warn "PostgreSQL processes still running - killing..."
        sudo pkill -9 postgres || true
        sleep 2
    fi

    log_info "Services stopped"
}

# -----------------------------------------------------------------------------
# Clear data directory
# -----------------------------------------------------------------------------

clear_data_directory() {
    log_info "Clearing data directory: $DATA_DIR"

    if [ -d "$DATA_DIR" ]; then
        sudo rm -rf "$DATA_DIR"/*
        log_info "Data directory cleared"
    else
        log_warn "Data directory does not exist - will be created during restore"
    fi
}

# -----------------------------------------------------------------------------
# Execute PITR
# -----------------------------------------------------------------------------

execute_restore() {
    log_info "Starting Point-in-Time Recovery..."
    log_info "Target: $TARGET_TIME"
    log_info "Stanza: $STANZA"

    local start_time
    start_time=$(date +%s)

    # Execute restore with PITR
    if sudo -u postgres pgbackrest --stanza="$STANZA" \
        --type=time \
        --target="$TARGET_TIME" \
        --target-action=promote \
        --delta \
        restore; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "Restore completed successfully!"
        log_info "Duration: ${duration} seconds"
    else
        log_error "Restore failed!"
        log_error "Check pgBackRest logs: /var/log/pgbackrest/"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Start services
# -----------------------------------------------------------------------------

start_services() {
    log_info "Starting Patroni..."
    sudo systemctl start patroni

    log_info "Waiting for PostgreSQL to be ready..."
    local max_wait=60
    local waited=0

    while ! sudo -u postgres /usr/bin/pg_isready -h localhost -p 5432 2>/dev/null; do
        if [ $waited -ge $max_wait ]; then
            log_error "PostgreSQL did not start within ${max_wait} seconds"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""

    log_info "PostgreSQL is ready!"
}

# -----------------------------------------------------------------------------
# Verify restore
# -----------------------------------------------------------------------------

verify_restore() {
    log_info "Verifying restore..."

    # Check Patroni status
    local patroni_status
    patroni_status=$(curl -s http://localhost:8008/patroni 2>/dev/null || echo "{}")

    echo ""
    log_info "Patroni status:"
    echo "$patroni_status" | jq . 2>/dev/null || echo "$patroni_status"
    echo ""

    # Check PostgreSQL recovery status
    local recovery_status
    recovery_status=$(sudo -u postgres psql -t -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

    if [ "$recovery_status" = " f" ] || [ "$recovery_status" = "f" ]; then
        log_info "PostgreSQL is PRIMARY (not in recovery)"
    elif [ "$recovery_status" = " t" ] || [ "$recovery_status" = "t" ]; then
        log_info "PostgreSQL is in RECOVERY mode"
    else
        log_warn "Could not determine recovery status: $recovery_status"
    fi

    # Check timeline
    local timeline
    timeline=$(sudo -u postgres psql -t -c "SELECT timeline_id FROM pg_control_checkpoint();" 2>/dev/null || echo "unknown")
    log_info "Current timeline: $timeline"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "=========================================="
    echo "  pgBackRest Point-in-Time Recovery"
    echo "=========================================="
    echo ""

    validate_input
    show_available_backups
    confirm_restore

    echo ""
    log_info "Starting PITR process..."
    echo ""

    stop_services
    clear_data_directory
    execute_restore
    start_services
    verify_restore

    echo ""
    log_info "=========================================="
    log_info "  PITR completed successfully!"
    log_info "=========================================="
    log_info "Database restored to: $TARGET_TIME"
    log_info ""
    log_info "IMPORTANT: Other cluster nodes may need to be"
    log_info "reinitialized to sync with the new timeline."
    log_info ""
}

main "$@"
