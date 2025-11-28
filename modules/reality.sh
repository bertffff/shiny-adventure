#!/bin/bash
# =============================================================================
# MODULE: reality.sh - Reality Protocol Keys Generation
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# REALITY KEYS GENERATION
# -----------------------------------------------------------------------------

readonly KEYS_DIR="/opt/marzban/keys"

# Generate X25519 key pair using sing-box or openssl
generate_x25519_keypair() {
    local private_key=""
    local public_key=""
    
    # Method 1: Try using sing-box (if available in Docker)
    if docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair 2>/dev/null; then
        log_debug "Using sing-box for key generation"
        local keypair
        keypair=$(docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair 2>/dev/null)
        private_key=$(echo "$keypair" | grep -i private | awk '{print $NF}')
        public_key=$(echo "$keypair" | grep -i public | awk '{print $NF}')
    fi
    
    # Method 2: Use xray (if sing-box didn't work)
    if [[ -z "$private_key" ]]; then
        log_debug "Trying xray for key generation"
        if docker run --rm teddysun/xray xray x25519 2>/dev/null; then
            local keypair
            keypair=$(docker run --rm teddysun/xray xray x25519 2>/dev/null)
            private_key=$(echo "$keypair" | grep -i private | awk -F: '{print $2}' | tr -d ' ')
            public_key=$(echo "$keypair" | grep -i public | awk -F: '{print $2}' | tr -d ' ')
        fi
    fi
    
    # Method 3: Use openssl and base64 conversion
    if [[ -z "$private_key" ]]; then
        log_debug "Using openssl for key generation"
        
        # Generate raw X25519 private key
        private_key=$(openssl genpkey -algorithm X25519 2>/dev/null | \
            openssl pkey -outform DER 2>/dev/null | \
            tail -c 32 | \
            base64 | tr -d '\n')
        
        # Derive public key
        public_key=$(echo -n "$private_key" | base64 -d | \
            openssl pkey -inform DER -pubout -outform DER 2>/dev/null | \
            tail -c 32 | \
            base64 | tr -d '\n')
    fi
    
    # Validate keys
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "Failed to generate X25519 key pair"
        return 1
    fi
    
    echo "PRIVATE_KEY=${private_key}"
    echo "PUBLIC_KEY=${public_key}"
}

# Generate Reality Short ID (8 hex characters)
generate_reality_short_id() {
    local short_id
    short_id=$(openssl rand -hex 4)
    echo "$short_id"
}

# Generate multiple Short IDs
generate_reality_short_ids() {
    local count="${1:-1}"
    local short_ids=()
    
    for ((i = 0; i < count; i++)); do
        short_ids+=("$(generate_reality_short_id)")
    done
    
    # Return as comma-separated list
    local IFS=','
    echo "${short_ids[*]}"
}

# Generate UUID for VLESS
generate_uuid() {
    if command_exists uuidgen; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# Save keys to file
save_keys() {
    local keys_file="${KEYS_DIR}/reality_keys.env"
    local private_key="$1"
    local public_key="$2"
    local short_ids="$3"
    
    create_dir "$KEYS_DIR" "0700"
    create_secure_file "$keys_file" "0600"
    
    cat > "$keys_file" << EOF
# Reality Keys - Generated $(date '+%Y-%m-%d %H:%M:%S')
# KEEP THIS FILE SECURE!

REALITY_PRIVATE_KEY="${private_key}"
REALITY_PUBLIC_KEY="${public_key}"
REALITY_SHORT_IDS="${short_ids}"
EOF
    
    log_success "Keys saved to ${keys_file}"
}

# Load existing keys
load_keys() {
    local keys_file="${KEYS_DIR}/reality_keys.env"
    
    if [[ -f "$keys_file" ]]; then
        source "$keys_file"
        log_info "Loaded existing Reality keys"
        return 0
    fi
    
    return 1
}

# Main function to setup Reality keys
setup_reality_keys() {
    log_step "Generating Reality Protocol Keys"
    
    # Check for existing keys
    if load_keys; then
        if confirm_action "Existing keys found. Generate new ones?" "n"; then
            log_info "Generating new keys..."
        else
            log_info "Using existing keys"
            echo "REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}"
            echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}"
            echo "REALITY_SHORT_IDS=${REALITY_SHORT_IDS}"
            return 0
        fi
    fi
    
    # Generate X25519 key pair
    log_info "Generating X25519 key pair..."
    local keypair
    keypair=$(generate_x25519_keypair)
    
    if [[ -z "$keypair" ]]; then
        log_error "Failed to generate key pair"
        return 1
    fi
    
    local private_key
    local public_key
    private_key=$(echo "$keypair" | grep PRIVATE_KEY | cut -d= -f2)
    public_key=$(echo "$keypair" | grep PUBLIC_KEY | cut -d= -f2)
    
    log_success "X25519 key pair generated"
    
    # Generate Short IDs (3 different ones)
    log_info "Generating Short IDs..."
    local short_ids
    short_ids=$(generate_reality_short_ids 3)
    log_success "Short IDs generated: ${short_ids}"
    
    # Save keys
    save_keys "$private_key" "$public_key" "$short_ids"
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}Reality Keys Generated Successfully${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}Private Key (SERVER ONLY):${NC}"
    echo -e "  ${private_key}"
    echo ""
    echo -e "${CYAN}Public Key (for clients):${NC}"
    echo -e "  ${public_key}"
    echo ""
    echo -e "${CYAN}Short IDs:${NC}"
    echo -e "  ${short_ids}"
    echo ""
    print_separator
    echo ""
    
    # Export for use in other scripts
    export REALITY_PRIVATE_KEY="$private_key"
    export REALITY_PUBLIC_KEY="$public_key"
    export REALITY_SHORT_IDS="$short_ids"
    
    echo "REALITY_PRIVATE_KEY=${private_key}"
    echo "REALITY_PUBLIC_KEY=${public_key}"
    echo "REALITY_SHORT_IDS=${short_ids}"
}

# Verify Reality server name (SNI) is accessible
verify_reality_sni() {
    local sni="$1"
    
    log_info "Verifying Reality SNI: ${sni}"
    
    # Check if domain resolves
    if ! host "$sni" &>/dev/null; then
        log_warn "SNI ${sni} does not resolve. This may cause issues."
        return 1
    fi
    
    # Check if HTTPS is accessible
    if ! curl -sf --connect-timeout 5 "https://${sni}" -o /dev/null 2>/dev/null; then
        log_warn "Cannot reach https://${sni}. Reality handshake may fail."
        return 1
    fi
    
    # Check TLS version
    local tls_version
    tls_version=$(echo | openssl s_client -connect "${sni}:443" -tls1_3 2>/dev/null | grep "Protocol" | awk '{print $3}')
    
    if [[ "$tls_version" == "TLSv1.3" ]]; then
        log_success "SNI ${sni} supports TLS 1.3 (required for Reality)"
    else
        log_warn "SNI ${sni} may not support TLS 1.3. Reality may not work properly."
    fi
    
    return 0
}

# Print Reality configuration for clients
print_reality_client_config() {
    local server_ip="$1"
    local port="$2"
    local public_key="$3"
    local short_id="$4"
    local sni="$5"
    local uuid="$6"
    
    echo ""
    print_separator
    echo -e "${GREEN}Reality Client Configuration${NC}"
    print_separator
    echo ""
    echo "Server: ${server_ip}"
    echo "Port: ${port}"
    echo "UUID: ${uuid}"
    echo "Flow: xtls-rprx-vision"
    echo "Public Key: ${public_key}"
    echo "Short ID: ${short_id}"
    echo "SNI: ${sni}"
    echo "Fingerprint: chrome"
    echo "Security: reality"
    echo ""
    print_separator
}
