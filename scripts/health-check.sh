#!/bin/bash
# =============================================================================
# Health Check Script
# =============================================================================
# Checks the status of the PostgreSQL HA cluster.
# Shows Patroni cluster status, etcd health, and NLB connectivity.
#
# Usage: ./scripts/health-check.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA Cluster Health Check${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Get infrastructure info
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)
PATRONI_IPS=($(get_patroni_ips))
ETCD_IPS=($(get_etcd_ips))

log_info "NLB DNS: $NLB_DNS"
log_info "Bastion IP: $BASTION_IP"
log_info "Patroni IPs: ${PATRONI_IPS[*]}"
log_info "etcd IPs: ${ETCD_IPS[*]}"
echo ""

# Check etcd cluster health
echo -e "${CYAN}--- etcd Cluster Status ---${NC}"
ETCD_IP="${ETCD_IPS[0]}"
log_info "Checking etcd via $ETCD_IP..."

if etcd_status=$(ssh_via_bastion "$ETCD_IP" "etcdctl endpoint status --cluster -w table 2>/dev/null"); then
    echo "$etcd_status"
else
    log_warn "Could not connect to etcd. Instance may still be bootstrapping."
fi
echo ""

# Check Patroni cluster status
echo -e "${CYAN}--- Patroni Cluster Status ---${NC}"
PATRONI_IP="${PATRONI_IPS[0]}"
log_info "Checking Patroni via $PATRONI_IP..."

if patroni_status=$(ssh_via_bastion "$PATRONI_IP" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
    echo "$patroni_status"
else
    log_warn "Could not connect to Patroni. Instance may still be bootstrapping."
fi
echo ""

# Check NLB connectivity (via bastion since NLB is internal)
echo -e "${CYAN}--- NLB Connectivity ---${NC}"
log_info "Testing PostgreSQL connection via NLB (from bastion)..."

if nlb_test=$(ssh_to_bastion "timeout 5 bash -c '</dev/tcp/$NLB_DNS/5432' 2>/dev/null && echo 'OK' || echo 'FAIL'"); then
    if [[ "$nlb_test" == *"OK"* ]]; then
        log_success "NLB port 5432 is reachable"
    else
        log_warn "NLB port 5432 not reachable yet (health checks may still be pending)"
    fi
else
    log_warn "Could not test NLB connectivity"
fi

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN} Health check complete${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
log_info "Next steps:"
echo -e "  - If cluster not ready, wait 5-10 minutes and try again"
echo -e "  - Run ${CYAN}./scripts/insert-loop.sh${NC} to test writes"
echo -e "  - Run ${CYAN}./scripts/chaos-test.sh${NC} to test failover"
