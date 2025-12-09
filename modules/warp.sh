#!/bin/bash
# =============================================================================
# MODULE: warp.sh - Cloudflare WARP Configuration Generator (Robust Version)
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# CLOUDFLARE WARP CONFIGURATION
# -----------------------------------------------------------------------------

readonly WARP_DIR="/opt/marzban/warp"
readonly WARP_CONFIG_FILE="${WARP_DIR}/warp.conf"
readonly WARP_OUTBOUND_FILE="${WARP_DIR}/warp_outbound.json"

# Install WireGuard tools if missing
install_wireguard_tools() {
    if ! command_exists wg; then
        log_info "Installing WireGuard tools..."
        apt-get update -qq
        apt-get install -y -qq wireguard-tools openresolv
    fi
}

# Generate WARP keys and register account via API directly
# This bypasses the need for the unstable wgcf binary
register_warp_api() {
    log_info "Registering WARP account via Cloudflare API..."
    
    # 1. Generate Keys
    local private_key
    local public_key
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    
    # 2. Register Device
    # We use a standard curl request mimicking the official client
    local install_id
    local fcm_token
    install_id=""
    fcm_token=""
    local tos_date
    tos_date=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    
    local response
    response=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        --data "{\"key\":\"${public_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${fcm_token}\",\"tos\":\"${tos_date}\",\"model\":\"Linux\",\"serial_number\":\"${install_id}\",\"locale\":\"en_US\"}")

    # 3. Check for success
    if [[ -z "$response" ]]; then
        log_error "Empty response from Cloudflare API"
        return 1
    fi
    
    local id
    id=$(echo "$response" | jq -r '.result.id // empty')
    
    if [[ -z "$id" ]]; then
        log_error "Registration failed. API Response: $response"
        return 1
    fi
    
    # 4. Extract Configuration
    local peer_pub
    local peer_endpoint
    local client_ipv4
    local client_ipv6
    
    peer_pub=$(echo "$response" | jq -r '.result.config.peers[0].public_key')
    peer_endpoint=$(echo "$response" | jq -r '.result.config.peers[0].endpoint.host')
    # Default fallback endpoint if API returns host that doesn't resolve
    if [[ "$peer_endpoint" == *"engage.cloudflareclient.com"* ]]; then
         # Use direct IP to avoid DNS pollution issues
         peer_endpoint="162.159.193.10"
    fi
    
    client_ipv4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4')
    client_ipv6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6')
    
    log_success "WARP Account ID: $id"
    
    # 5. Create WireGuard Config (standard format for reference)
    cat > "$WARP_CONFIG_FILE" << EOF
[Interface]
PrivateKey = ${private_key}
Address = ${client_ipv4}, ${client_ipv6}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${peer_pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${peer_endpoint}:2408
EOF
    
    chmod 0600 "$WARP_CONFIG_FILE"
    
    # 6. Generate Xray JSON Outbound
    # Extract IP only (remove CIDR) for Xray config
    local ip4_addr="${client_ipv4%/*}"
    local ip6_addr="${client_ipv6%/*}"
    
    cat > "$WARP_OUTBOUND_FILE" << EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${private_key}",
    "address": [
      "${ip4_addr}/32",
      "${ip6_addr}/128"
    ],
    "peers": [
      {
        "publicKey": "${peer_pub}",
        "allowedIPs": [
          "0.0.0.0/0",
          "::/0"
        ],
        "endpoint": "${peer_endpoint}:2408"
      }
    ],
    "mtu": 1280,
    "reserved": [0, 0, 0]
  }
}
EOF
    chmod 0644 "$WARP_OUTBOUND_FILE"
    
    log_success "WARP configuration generated successfully."
    return 0
}

# Test WARP connectivity
test_warp_connectivity() {
    log_info "Testing WARP endpoint connectivity..."
    
    if [[ ! -f "$WARP_CONFIG_FILE" ]]; then
        log_error "WARP config not found"
        return 1
    fi
    
    # Extract endpoint from config
    local endpoint
    endpoint=$(grep "Endpoint" "$WARP_CONFIG_FILE" | awk '{print $3}' | cut -d: -f1)
    local port
    port=$(grep "Endpoint" "$WARP_CONFIG_FILE" | awk '{print $3}' | cut -d: -f2)

    # Use nc (netcat) to check UDP reachability (basic check)
    if nc -z -u -w 3 "$endpoint" "$port"; then
        log_success "WARP Endpoint ($endpoint:$port) is reachable via UDP."
    else
        log_warn "WARP Endpoint ($endpoint:$port) UDP check failed. This might be blocked by provider or firewall."
        # Try a fallback IP if primary fails
        log_info "Trying to patch config with fallback IP..."
        sed -i 's/Endpoint = .*/Endpoint = 162.159.192.1:2408/' "$WARP_CONFIG_FILE"
        sed -i 's/"endpoint": ".*"/"endpoint": "162.159.192.1:2408"/' "$WARP_OUTBOUND_FILE"
        log_success "Patched endpoint to 162.159.192.1. Please restart Marzban."
    fi
}

# Main Setup Function
setup_warp() {
    log_step "Setting up Cloudflare WARP"
    
    create_dir "$WARP_DIR" "0700"
    install_wireguard_tools
    
    if register_warp_api; then
        test_warp_connectivity
        
        echo ""
        print_separator
        echo -e "${GREEN}WARP Setup Completed${NC}"
        echo "Config: $WARP_CONFIG_FILE"
        echo "Xray JSON: $WARP_OUTBOUND_FILE"
        print_separator
        echo ""
    else
        log_error "Failed to setup WARP. Profile 3 (Via-WARP) might not work."
    fi
}
