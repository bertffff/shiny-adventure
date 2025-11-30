#!/bin/bash
# =============================================================================
# MODULE: warp.sh - Cloudflare WARP Configuration Generator
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# CLOUDFLARE WARP CONFIGURATION
# -----------------------------------------------------------------------------

readonly WARP_DIR="/opt/marzban/warp"
readonly WARP_CONFIG_FILE="${WARP_DIR}/warp.conf"

# Install wgcf (WireGuard configuration generator for WARP)
install_wgcf() {
    log_info "Installing wgcf..."
    
    local arch
    arch=$(uname -m)
    
    local wgcf_url=""
    case "$arch" in
        x86_64)
            wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
            ;;
        aarch64)
            wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_arm64"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac
    
    # Download wgcf
    curl -fsSL "$wgcf_url" -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    
    register_file "/usr/local/bin/wgcf"
    register_rollback "Remove wgcf" "rm -f /usr/local/bin/wgcf"
    
    log_success "wgcf installed"
}

# Register new WARP account
register_warp_account() {
    local work_dir="${1:-$WARP_DIR}"
    
    log_info "Registering Cloudflare WARP account..."
    
    create_dir "$work_dir" "0700"
    cd "$work_dir"
    
    # Accept ToS non-interactively
    yes | wgcf register 2>/dev/null || true
    
    if [[ ! -f "${work_dir}/wgcf-account.toml" ]]; then
        log_error "WARP account registration failed"
        return 1
    fi
    
    register_file "${work_dir}/wgcf-account.toml"
    
    log_success "WARP account registered"
}

# Generate WireGuard configuration
generate_warp_config() {
    local work_dir="${1:-$WARP_DIR}"
    
    log_info "Generating WARP WireGuard configuration..."
    
    cd "$work_dir"
    
    # Generate WireGuard config
    wgcf generate
    
    if [[ ! -f "${work_dir}/wgcf-profile.conf" ]]; then
        log_error "WARP config generation failed"
        return 1
    fi
    
    # Rename to our standard name
    mv "${work_dir}/wgcf-profile.conf" "$WARP_CONFIG_FILE"
    chmod 0600 "$WARP_CONFIG_FILE"
    
    register_file "$WARP_CONFIG_FILE"
    
    log_success "WARP config generated: ${WARP_CONFIG_FILE}"
}

# Parse WARP config and extract values
parse_warp_config() {
    local config_file="${1:-$WARP_CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "WARP config file not found: ${config_file}"
        return 1
    fi
    
    # Extract values
    local private_key
    local address_v4
    local address_v6
    local public_key
    local endpoint
    local mtu
    
    private_key=$(grep -E "^PrivateKey\s*=" "$config_file" | cut -d= -f2 | tr -d ' ')
    address_v4=$(grep -E "^Address\s*=" "$config_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
    address_v6=$(grep -E "^Address\s*=" "$config_file" | grep -oE '[0-9a-f:]+/[0-9]+' | head -1)
    public_key=$(grep -E "^PublicKey\s*=" "$config_file" | cut -d= -f2 | tr -d ' ')
    endpoint=$(grep -E "^Endpoint\s*=" "$config_file" | cut -d= -f2 | tr -d ' ')
    mtu=$(grep -E "^MTU\s*=" "$config_file" | cut -d= -f2 | tr -d ' ')
    
    # Set defaults if not found
    mtu="${mtu:-1280}"
    
    # Extract endpoint host and port
    local endpoint_host
    local endpoint_port
    endpoint_host=$(echo "$endpoint" | cut -d: -f1)
    endpoint_port=$(echo "$endpoint" | cut -d: -f2)
    
    # Output as environment variables
    echo "WARP_PRIVATE_KEY=${private_key}"
    echo "WARP_ADDRESS_V4=${address_v4}"
    echo "WARP_ADDRESS_V6=${address_v6}"
    echo "WARP_PUBLIC_KEY=${public_key}"
    echo "WARP_ENDPOINT_HOST=${endpoint_host}"
    echo "WARP_ENDPOINT_PORT=${endpoint_port}"
    echo "WARP_MTU=${mtu}"
}

# Generate sing-box outbound configuration for WARP
generate_singbox_warp_outbound() {
    local config_file="${1:-$WARP_CONFIG_FILE}"
    local output_file="${2:-${WARP_DIR}/warp_outbound.json}"
    
    log_info "Generating sing-box WARP outbound configuration..."
    
    # Parse WARP config
    local warp_vars
    warp_vars=$(parse_warp_config "$config_file")
    
    if [[ -z "$warp_vars" ]]; then
        log_error "Failed to parse WARP config"
        return 1
    fi
    
    # Export variables
    eval "$warp_vars"
    
    # Generate sing-box WireGuard outbound JSON
    cat > "$output_file" << EOF
{
  "type": "wireguard",
  "tag": "warp-out",
  "server": "${WARP_ENDPOINT_HOST}",
  "server_port": ${WARP_ENDPOINT_PORT},
  "local_address": [
    "${WARP_ADDRESS_V4}",
    "${WARP_ADDRESS_V6}"
  ],
  "private_key": "${WARP_PRIVATE_KEY}",
  "peer_public_key": "${WARP_PUBLIC_KEY}",
  "reserved": [0, 0, 0],
  "mtu": ${WARP_MTU}
}
EOF
    
    chmod 0600 "$output_file"
    register_file "$output_file"
    
    log_success "sing-box WARP outbound config saved to ${output_file}"
    
    # Print the config for verification
    log_debug "WARP outbound configuration:"
    cat "$output_file" | jq '.' 2>/dev/null || cat "$output_file"
}

# Test WARP connectivity
test_warp_connectivity() {
    log_info "Testing WARP connectivity..."
    
    local warp_vars
    warp_vars=$(parse_warp_config "$WARP_CONFIG_FILE")
    
    if [[ -z "$warp_vars" ]]; then
        log_error "Cannot test WARP - config not found"
        return 1
    fi
    
    eval "$warp_vars"
    
    # Check if endpoint is reachable
    if nc -z -w5 "${WARP_ENDPOINT_HOST}" "${WARP_ENDPOINT_PORT}" 2>/dev/null; then
        log_success "WARP endpoint ${WARP_ENDPOINT_HOST}:${WARP_ENDPOINT_PORT} is reachable"
        return 0
    else
        log_warn "WARP endpoint may not be reachable (UDP test inconclusive)"
        return 0  # UDP connectivity check is unreliable
    fi
}

# Save WARP configuration summary
save_warp_summary() {
    local summary_file="${WARP_DIR}/warp_summary.txt"
    
    log_info "Saving WARP configuration summary..."
    
    local warp_vars
    warp_vars=$(parse_warp_config "$WARP_CONFIG_FILE")
    
    if [[ -z "$warp_vars" ]]; then
        return 1
    fi
    
    eval "$warp_vars"
    
    cat > "$summary_file" << EOF
# Cloudflare WARP Configuration Summary
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# =====================================

Endpoint: ${WARP_ENDPOINT_HOST}:${WARP_ENDPOINT_PORT}
IPv4 Address: ${WARP_ADDRESS_V4}
IPv6 Address: ${WARP_ADDRESS_V6}
MTU: ${WARP_MTU}

# NOTE: Private key stored in ${WARP_CONFIG_FILE}
EOF
    
    chmod 0644 "$summary_file"
    register_file "$summary_file"
    
    log_success "WARP summary saved to ${summary_file}"
}

# Main WARP setup function
setup_warp() {
    log_step "Setting up Cloudflare WARP"
    
    # Check for existing WARP config
    if [[ -f "$WARP_CONFIG_FILE" ]]; then
        log_info "Existing WARP configuration found"
        
        if confirm_action "Use existing WARP config?" "y"; then
            generate_singbox_warp_outbound
            save_warp_summary
            return 0
        fi
    fi
    
    # Install wgcf
    if ! command_exists wgcf; then
        install_wgcf
    fi
    
    # Create WARP directory
    create_dir "$WARP_DIR" "0700"
    
    # Register account
    register_warp_account "$WARP_DIR"
    
    # Generate config
    generate_warp_config "$WARP_DIR"
    
    # Generate sing-box outbound
    generate_singbox_warp_outbound
    
    # Save summary
    save_warp_summary
    
    # Test connectivity
    test_warp_connectivity
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}WARP Configuration Complete${NC}"
    print_separator
    echo ""
    cat "${WARP_DIR}/warp_summary.txt"
    echo ""
    print_separator
    
    log_success "WARP setup completed"
}

# Alternative: Use warp-reg API for WARP registration
# (Fallback if wgcf doesn't work)
setup_warp_via_api() {
    log_info "Attempting WARP registration via API..."
    
    create_dir "$WARP_DIR" "0700"
    
    # Generate WireGuard key pair
    local private_key
    local public_key
    
    private_key=$(wg genkey 2>/dev/null || openssl rand -base64 32)
    public_key=$(echo "$private_key" | wg pubkey 2>/dev/null)
    
    if [[ -z "$public_key" ]]; then
        log_error "Failed to generate WireGuard keys"
        return 1
    fi
    
    # Call Cloudflare API to register device
    local response
    response=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "CF-Client-Version: a-6.11-2223" \
        --data "{\"key\":\"${public_key}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"Linux\",\"serial_number\":\"$(generate_alphanum 16)\"}")

    # Check if response is valid and contains config
    if [[ -z "$response" ]] || ! echo "$response" | jq -e '.result.config' &>/dev/null; then
        log_error "WARP API registration failed"
        return 1
    fi
    
    # Parse response and create config
    local config
    config=$(echo "$response" | jq -r '.result.config')
    
    # Extract peer config
    local peer_public_key
    local endpoint_host
    local endpoint_port
    local address_v4
    local address_v6
    
    peer_public_key=$(echo "$config" | jq -r '.peers[0].public_key')
    endpoint_host=$(echo "$config" | jq -r '.peers[0].endpoint.host')
    endpoint_port=$(echo "$config" | jq -r '.peers[0].endpoint.port // 2408')
    address_v4=$(echo "$config" | jq -r '.interface.addresses.v4')
    address_v6=$(echo "$config" | jq -r '.interface.addresses.v6')
    
    # Create WireGuard config file
    cat > "$WARP_CONFIG_FILE" << EOF
[Interface]
PrivateKey = ${private_key}
Address = ${address_v4}/32, ${address_v6}/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint_host}:${endpoint_port}
EOF
    
    chmod 0600 "$WARP_CONFIG_FILE"
    register_file "$WARP_CONFIG_FILE"
    
    log_success "WARP registered via API"
    
    # Generate sing-box outbound
    generate_singbox_warp_outbound
    save_warp_summary
}
