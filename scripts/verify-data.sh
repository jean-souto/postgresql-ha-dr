#!/bin/bash
# =============================================================================
# Verify Data Script
# =============================================================================
# Verifies data integrity after failover tests.
# Shows row counts, latest entries, and any gaps in the sequence.
#
# Usage: ./scripts/verify-data.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA Data Verification${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Get Patroni IPs
PATRONI_IPS=($(get_patroni_ips))
PATRONI_IP="${PATRONI_IPS[0]}"

log_info "Connecting via Patroni node ($PATRONI_IP)"
echo ""

# Check if table exists
TABLE_CHECK=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c '\dt test_ha' 2>/dev/null")

if [[ -z "$TABLE_CHECK" ]] || [[ "$TABLE_CHECK" != *"test_ha"* ]]; then
    log_warn "Table 'test_ha' does not exist. Run ${CYAN}./scripts/insert-loop.sh${NC} first."
    exit 0
fi

# Get statistics - verify based on DATA column, not ID (sequences can have gaps)
echo -e "${CYAN}--- Data Statistics ---${NC}"
TOTAL_ROWS=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c 'SELECT COUNT(*) FROM test_ha' 2>/dev/null" | tr -d ' ')
MAX_ID=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c 'SELECT COALESCE(MAX(id), 0) FROM test_ha' 2>/dev/null" | tr -d ' ')

# Extract max counter from data column (insert-N -> N)
MAX_COUNTER=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c \"SELECT COALESCE(MAX(CAST(SUBSTRING(data FROM 'insert-([0-9]+)') AS INTEGER)), 0) FROM test_ha\" 2>/dev/null" | tr -d ' ')

echo -e "Total Rows:     ${BOLD}$TOTAL_ROWS${NC}"
echo -e "Max Counter:    ${BOLD}$MAX_COUNTER${NC} (from data column)"
echo -e "Max ID:         ${BOLD}$MAX_ID${NC} (sequence - gaps are normal)"

# Check for DATA gaps (actual lost inserts)
if [[ "$MAX_COUNTER" != "$TOTAL_ROWS" ]] && [[ "$MAX_COUNTER" -gt 0 ]]; then
    DATA_GAPS=$((MAX_COUNTER - TOTAL_ROWS))
    echo -e "Data Gaps:      ${RED}$DATA_GAPS${NC} (ACTUAL DATA LOSS - inserts failed permanently)"

    # Show which inserts are missing
    echo ""
    echo -e "${YELLOW}Missing insert numbers:${NC}"
    ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c \"
        WITH expected AS (SELECT generate_series(1, $MAX_COUNTER) AS n),
             actual AS (SELECT CAST(SUBSTRING(data FROM 'insert-([0-9]+)') AS INTEGER) AS n FROM test_ha)
        SELECT 'insert-' || e.n FROM expected e LEFT JOIN actual a ON e.n = a.n WHERE a.n IS NULL LIMIT 20
    \" 2>/dev/null"
else
    echo -e "Data Gaps:      ${GREEN}None - all inserts preserved!${NC}"
fi

# ID gaps are informational only
if [[ "$MAX_ID" != "$TOTAL_ROWS" ]]; then
    ID_GAPS=$((MAX_ID - TOTAL_ROWS))
    echo -e "ID Gaps:        ${CYAN}$ID_GAPS${NC} (normal - failed transactions consumed sequence)"
fi
echo ""

# Get last 10 entries
echo -e "${CYAN}--- Last 10 Entries ---${NC}"
ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -c 'SELECT * FROM test_ha ORDER BY id DESC LIMIT 10' 2>/dev/null"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN} Verification complete${NC}"
echo -e "${BOLD}========================================${NC}"
