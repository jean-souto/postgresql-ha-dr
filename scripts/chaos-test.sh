#!/bin/bash
# =============================================================================
# Chaos Test Script
# =============================================================================
# Tests PostgreSQL HA failover by killing the primary node.
# Run insert-loop.sh in another terminal to observe behavior.
#
# Usage: ./scripts/chaos-test.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA Chaos Test${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Get infrastructure info
BASTION_IP=$(get_bastion_ip)
PATRONI_IPS=($(get_patroni_ips))

log_info "Patroni IPs: ${PATRONI_IPS[*]}"
echo ""

# Find current leader using Patroni API (more reliable than index-based lookup)
log_info "Finding current cluster leader..."

LEADER_IP=""
LEADER_NAME=""
CLUSTER_OUTPUT=""

for ip in "${PATRONI_IPS[@]}"; do
    # First, try to get cluster status from this node
    if CLUSTER_OUTPUT=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
        if [[ -n "$CLUSTER_OUTPUT" ]]; then
            # Now check each node's Patroni API to find the actual leader
            for check_ip in "${PATRONI_IPS[@]}"; do
                # Query Patroni API - returns 200 only if this node is the leader
                api_response=$(ssh_via_bastion "$check_ip" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/leader 2>/dev/null" || echo "000")
                if [[ "$api_response" == "200" ]]; then
                    LEADER_IP="$check_ip"
                    # Get the node name from the API
                    LEADER_NAME=$(ssh_via_bastion "$check_ip" "curl -s http://localhost:8008/patroni 2>/dev/null | grep -oE '\"name\": *\"[^\"]+\"' | cut -d'\"' -f4" || echo "unknown")
                    break 2
                fi
            done
            break
        fi
    fi
done

if [[ -z "$LEADER_IP" ]]; then
    log_error "Could not find cluster leader. Is the cluster running?"
    exit 1
fi

log_success "Current leader: ${BOLD}$LEADER_NAME${NC} ${GREEN}($LEADER_IP)${NC}"
echo ""

# Show cluster status before (use already fetched output)
echo -e "${CYAN}--- Cluster Status BEFORE Chaos ---${NC}"
echo "$CLUSTER_OUTPUT"
echo ""

# Menu
echo -e "${BOLD}Select chaos action:${NC}"
echo -e "  ${CYAN}1.${NC} Stop Patroni service (graceful)"
echo -e "  ${CYAN}2.${NC} Kill PostgreSQL process (crash)"
echo -e "  ${CYAN}3.${NC} Patroni failover command (planned)"
echo -e "  ${CYAN}4.${NC} Just monitor (no chaos)"
echo -e "  ${CYAN}5.${NC} Stop EC2 instance (hardware failure)"
echo ""

read -p "Enter choice (1-5): " choice || choice=""

case $choice in
    1)
        echo ""
        log_action "Stopping Patroni on $LEADER_NAME..."
        ssh_via_bastion "$LEADER_IP" "sudo systemctl stop patroni"
        log_success "Patroni stopped. Failover should occur in ~10-30 seconds."
        ;;
    2)
        echo ""
        log_action "Killing PostgreSQL on $LEADER_NAME..."
        ssh_via_bastion "$LEADER_IP" "sudo pkill -9 postgres"
        log_success "PostgreSQL killed. Patroni should restart it or trigger failover."
        ;;
    3)
        echo ""
        log_action "Triggering Patroni failover..."

        # Find a replica to fail over to using Patroni API
        CANDIDATE=""
        CANDIDATE_IP=""
        for check_ip in "${PATRONI_IPS[@]}"; do
            if [[ "$check_ip" != "$LEADER_IP" ]]; then
                # Check if this replica is healthy
                replica_status=$(ssh_via_bastion "$check_ip" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/replica 2>/dev/null" || echo "000")
                if [[ "$replica_status" == "200" ]]; then
                    CANDIDATE_IP="$check_ip"
                    CANDIDATE=$(ssh_via_bastion "$check_ip" "curl -s http://localhost:8008/patroni 2>/dev/null | grep -oE '\"name\": *\"[^\"]+\"' | cut -d'\"' -f4" || echo "")
                    break
                fi
            fi
        done

        if [[ -n "$CANDIDATE" ]]; then
            log_info "Failing over to $CANDIDATE ($CANDIDATE_IP)..."
            ssh_via_bastion "$LEADER_IP" "sudo patronictl -c /etc/patroni/patroni.yml failover --candidate $CANDIDATE --force 2>/dev/null"
        else
            log_warn "No healthy replica found, letting Patroni choose..."
            ssh_via_bastion "$LEADER_IP" "sudo patronictl -c /etc/patroni/patroni.yml failover --force 2>/dev/null"
        fi
        log_success "Failover initiated."
        ;;
    4)
        echo ""
        log_info "Monitor mode - no chaos action taken."
        ;;
    5)
        echo ""
        log_action "Stopping EC2 instance for $LEADER_NAME ($LEADER_IP)..."

        # Get instance ID from private IP
        INSTANCE_ID=$(aws ec2 describe-instances \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --filters "Name=private-ip-address,Values=$LEADER_IP" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)

        if [[ -z "$INSTANCE_ID" ]] || [[ "$INSTANCE_ID" == "None" ]]; then
            log_error "Could not find instance ID for IP $LEADER_IP"
            exit 1
        fi

        log_info "Instance ID: $INSTANCE_ID"

        # Stop the instance
        aws ec2 stop-instances \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --instance-ids "$INSTANCE_ID" > /dev/null 2>&1

        if [[ $? -eq 0 ]]; then
            log_success "EC2 stop command sent. Instance will stop in ~30-60 seconds."
            log_warn "This simulates complete hardware failure!"
        else
            log_error "Failed to stop instance. Check AWS credentials and permissions."
            exit 1
        fi
        ;;
    *)
        log_error "Invalid choice."
        exit 1
        ;;
esac

# Wait and show status after
if [[ "$choice" != "4" ]]; then
    echo ""

    # EC2 stop takes longer
    if [[ "$choice" == "5" ]]; then
        WAIT_TIME=45
        log_info "Waiting $WAIT_TIME seconds for EC2 to stop and failover..."
    else
        WAIT_TIME=15
        log_info "Waiting $WAIT_TIME seconds for failover..."
    fi

    for i in $(seq $WAIT_TIME -1 1); do
        echo -ne "\r${YELLOW}[WAIT]${NC} $i seconds remaining...  "
        sleep 1
    done
    echo ""
fi

echo ""
echo -e "${CYAN}--- Cluster Status AFTER Chaos ---${NC}"

# Try each IP until one responds
STATUS_FOUND=false
for ip in "${PATRONI_IPS[@]}"; do
    if status_after=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
        if [[ -n "$status_after" ]]; then
            echo "$status_after"
            STATUS_FOUND=true
            break
        fi
    fi
done

if [[ "$STATUS_FOUND" == "false" ]]; then
    log_warn "Could not get cluster status. Nodes may still be recovering..."
fi

# Find and display new leader
echo ""
NEW_LEADER_IP=""
NEW_LEADER_NAME=""
for check_ip in "${PATRONI_IPS[@]}"; do
    api_response=$(ssh_via_bastion "$check_ip" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/leader 2>/dev/null" || echo "000")
    if [[ "$api_response" == "200" ]]; then
        NEW_LEADER_IP="$check_ip"
        NEW_LEADER_NAME=$(ssh_via_bastion "$check_ip" "curl -s http://localhost:8008/patroni 2>/dev/null | grep -oE '\"name\": *\"[^\"]+\"' | cut -d'\"' -f4" || echo "unknown")
        break
    fi
done

if [[ -n "$NEW_LEADER_IP" ]]; then
    if [[ "$NEW_LEADER_IP" == "$LEADER_IP" ]]; then
        log_info "Leader unchanged: ${BOLD}$NEW_LEADER_NAME${NC} ($NEW_LEADER_IP)"
    else
        log_success "New leader: ${BOLD}$NEW_LEADER_NAME${NC} ${GREEN}($NEW_LEADER_IP)${NC}"
    fi
else
    log_warn "No leader found yet. Cluster may still be electing..."
fi

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN} Chaos test complete${NC}"
echo -e "${BOLD}========================================${NC}"

# Recovery and reintegration test
case $choice in
    1)
        echo ""
        read -p "Do you want to restore the node and verify reintegration? (y/n): " restore_choice || restore_choice="n"
        if [[ "$restore_choice" == "y" || "$restore_choice" == "Y" ]]; then
            echo ""
            log_action "Starting Patroni on $LEADER_NAME..."
            ssh_via_bastion "$LEADER_IP" "sudo systemctl start patroni"
            log_success "Patroni start command sent."

            echo ""
            log_info "Waiting 20 seconds for node to rejoin cluster..."
            for i in $(seq 20 -1 1); do
                echo -ne "\r${YELLOW}[WAIT]${NC} $i seconds remaining...  "
                sleep 1
            done
            echo ""

            echo ""
            echo -e "${CYAN}--- Cluster Status AFTER Recovery ---${NC}"
            for ip in "${PATRONI_IPS[@]}"; do
                if recovery_status=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
                    if [[ -n "$recovery_status" ]]; then
                        echo "$recovery_status"
                        break
                    fi
                fi
            done
            log_success "Node reintegration complete!"
        fi
        ;;
    5)
        echo ""
        read -p "Do you want to restore the EC2 instance and verify reintegration? (y/n): " restore_choice || restore_choice="n"
        if [[ "$restore_choice" == "y" || "$restore_choice" == "Y" ]]; then
            echo ""
            log_action "Starting EC2 instance $INSTANCE_ID..."
            aws ec2 start-instances \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --instance-ids "$INSTANCE_ID" > /dev/null 2>&1

            if [[ $? -ne 0 ]]; then
                log_error "Failed to start instance."
                exit 1
            fi

            log_success "EC2 start command sent."

            echo ""
            log_info "Waiting for instance to be running..."
            aws ec2 wait instance-running \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --instance-ids "$INSTANCE_ID" 2>/dev/null

            log_success "Instance is running."

            echo ""
            log_info "Waiting 45 seconds for Patroni to start and rejoin cluster..."
            for i in $(seq 45 -1 1); do
                echo -ne "\r${YELLOW}[WAIT]${NC} $i seconds remaining...  "
                sleep 1
            done
            echo ""

            echo ""
            echo -e "${CYAN}--- Cluster Status AFTER Recovery ---${NC}"
            for ip in "${PATRONI_IPS[@]}"; do
                if recovery_status=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
                    if [[ -n "$recovery_status" ]]; then
                        echo "$recovery_status"
                        break
                    fi
                fi
            done
            log_success "Node reintegration complete!"
        else
            echo ""
            log_info "To restore manually:"
            echo -e "  ${CYAN}aws ec2 start-instances --profile $AWS_PROFILE --region $AWS_REGION --instance-ids $INSTANCE_ID${NC}"
        fi
        ;;
esac
