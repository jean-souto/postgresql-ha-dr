#!/bin/bash
# =============================================================================
# Insert Loop Script
# =============================================================================
# Continuously inserts data into PostgreSQL via NLB to test HA.
# Run this in one terminal while running chaos-test.sh in another.
#
# Usage: ./scripts/insert-loop.sh
# Press Ctrl+C to stop
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA Insert Loop Test${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Get NLB DNS and Bastion IP
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)

log_info "NLB: $NLB_DNS"
log_info "Connecting via bastion: $BASTION_IP"
echo ""

# Get postgres password from SSM (via bastion)
log_info "Retrieving postgres password..."
PG_PASSWORD=$(ssh_to_bastion "aws ssm get-parameter --name /pgha/postgres-password --with-decryption --query Parameter.Value --output text 2>/dev/null")

if [[ -z "$PG_PASSWORD" ]]; then
    log_error "Failed to retrieve postgres password from SSM"
    exit 1
fi

# Create table if not exists
log_info "Creating table if not exists..."
CREATE_RESULT=$(ssh_to_bastion "PGPASSWORD='$PG_PASSWORD' psql -h '$NLB_DNS' -U postgres -c 'CREATE TABLE IF NOT EXISTS test_ha (id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT NOW(), data TEXT)' 2>&1")

if [[ "$CREATE_RESULT" == *"CREATE TABLE"* ]] || [[ "$CREATE_RESULT" == *"already exists"* ]]; then
    log_success "Table ready"
else
    log_warn "Table creation result: $CREATE_RESULT"
fi

echo ""
log_info "Starting insert loop via bastion -> NLB..."
log_info "Press Ctrl+C to stop"
echo ""

# Run insert loop on bastion with TTY for live output
ssh -t $SSH_OPTS -i "$SSH_KEY_PATH" "ec2-user@$BASTION_IP" bash -c "'
export PGPASSWORD=\"$PG_PASSWORD\"
NLB=\"$NLB_DNS\"

# Colors for remote output
GREEN=\"\033[0;32m\"
RED=\"\033[0;31m\"
YELLOW=\"\033[1;33m\"
CYAN=\"\033[0;36m\"
NC=\"\033[0m\"

# Retry configuration (tuned for EC2 hardware failure scenarios)
# EC2 stop + NLB failover can take 60-90 seconds
MAX_RETRIES=60
RETRY_DELAY=2

counter=0
total_retries=0

while true; do
    counter=\$((counter + 1))
    attempt=1
    success=false

    while [ \$attempt -le \$MAX_RETRIES ]; do
        ts=\$(date \"+%Y-%m-%d %H:%M:%S\")
        result=\$(psql -h \"\$NLB\" -U postgres -t -c \"INSERT INTO test_ha (data) VALUES ('\''insert-\$counter'\'') RETURNING id\" 2>&1)

        if [ \$? -eq 0 ]; then
            id=\$(echo \"\$result\" | grep -oE \"[0-9]+\" | head -1)
            if [ \$attempt -eq 1 ]; then
                echo -e \"\${CYAN}[\$ts]\${NC} \${GREEN}INSERT #\$counter -> id=\$id\${NC}\"
            else
                echo -e \"\${CYAN}[\$ts]\${NC} \${GREEN}INSERT #\$counter -> id=\$id\${NC} \${YELLOW}(retry \$((attempt-1)))\${NC}\"
                total_retries=\$((total_retries + attempt - 1))
            fi
            success=true
            break
        else
            if [ \$attempt -lt \$MAX_RETRIES ]; then
                echo -e \"\${CYAN}[\$ts]\${NC} \${YELLOW}INSERT #\$counter attempt \$attempt failed, retrying in \${RETRY_DELAY}s...\${NC}\"
                sleep \$RETRY_DELAY
            else
                echo -e \"\${CYAN}[\$ts]\${NC} \${RED}INSERT #\$counter FAILED after \$MAX_RETRIES attempts: \$result\${NC}\"
            fi
        fi
        attempt=\$((attempt + 1))
    done

    sleep 1
done
'"
