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

# Get latest wgcf release version from GitHub
get_latest_wgcf_version() {
    local version
    
    # Try GitHub API first
    version=$(curl -sf --max-time 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null | \
        grep -oP '"tag_name":\s*"v?\K[^"]+' | head -1)
    
    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    
    # Fallback to known stable version
    echo "2.2.22"
}

# Install wgcf (WireGuard configuration generator for WARP)
install_wgcf() {
    log_info "Installing wgcf..."
    
    local arch
    arch=$(uname -m)
    
    # Get latest version
    local version
    version=$(get_latest_wgcf_version)
    log_info "Using wgcf version: ${version}"
    
    local wgcf_url=""
    case "$arch" in
        x86_64)
            wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_linux_amd64"
            ;;
        aarch64)
            wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_linux_arm64"
            ;;
        armv7l)
            wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_linux_armv7"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac
    
    # Download wgcf with timeout
    log_info "Downloading wgcf from ${wgcf_url}..."
    if ! timeout 60 curl -fsSL "$wgcf_url" -o /usr/local/bin/wgcf; then
        log_error "Failed to download wgcf"
        return 1
    fi
    
    chmod +x /usr/local/bin/wgcf
    
    # Verify installation
    if ! /usr/local/bin/wgcf --version &>/dev/null; then
        log_error "wgcf installation verification failed"
        rm -f /usr/local/bin/wgcf
        return 1
    fi
    
    register_file "/usr/local/bin/wgcf"
    register_rollback "Remove wgcf" "rm -f /usr/local/bin/wgcf" "cleanup"
    
    log_success "wgcf installed: $(/usr/local/bin/wgcf --version 2>/dev/null || echo 'version unknown')"
}

# Register new WARP account
register_warp_account() {
    local work_dir="${1:-$WARP_DIR}"
    
    log_info "Registering Cloudflare WARP account..."
    
    create_dir "$work_dir" "0700"
    
    # Change to work directory
    local original_dir
    original_dir=$(pwd)
    cd "$work_dir" || return 1
    
    # Accept ToS non-interactively
    if ! yes | wgcf register 2>/dev/null; then
        # Sometimes first attempt fails, try again
        sleep 2
        yes | wgcf register 2>/dev/null || true
    fi
    
    cd "$original_dir"
    
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
    
    local original_dir
    original_dir=$(pwd)
    cd "$work_dir" || return 1
    
    # Generate WireGuard config
    if ! wgcf generate; then
        log_error "WARP config generation failed"
        cd "$original_dir"
        return 1
    fi
    
    cd "$original_dir"
    
    if [[ ! -f "${work_dir}/wgcf-profile.conf" ]]; then
        log_error "WARP config file not created"
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
    
    # Extract values using more robust parsing
    local private_key=""
    local address_v4=""
    local address_v6=""
    local public_key=""
    local endpoint=""
    local mtu=""
    
    while IFS='=' read -r key value; do
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        case "$key" in
            PrivateKey)
                private_key="$value"
                ;;
            Address)
                # Address can have multiple values separated by comma
                if [[ "$value" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]]; then
                    address_v4="${BASH_REMATCH[1]}"
                fi
                if [[ "$value" =~ ([0-9a-f:]+/[0-9]+) ]]; then
                    address_v6="${BASH_REMATCH[1]}"
                fi
                ;;
            PublicKey)
                public_key="$value"
                ;;
            Endpoint)
                endpoint="$value"
                ;;
            MTU)
                mtu="$value"
                ;;
        esac
    done < "$config_file"
    
    # Set defaults if not found
    mtu="${mtu:-1280}"
    
    # Validate required fields
    if [[ -z "$private_key" || -z "$public_key" || -z "$endpoint" ]]; then
        log_error "Missing required fields in WARP config"
        return 1
    fi
    
    # Extract endpoint host and port
    local endpoint_host
    local endpoint_port
    endpoint_host="${endpoint%:*}"
    endpoint_port="${endpoint##*:}"
    
    # Output as environment variables
    echo "WARP_PRIVATE_KEY=${private_key}"
    echo "WARP_ADDRESS_V4=${address_v4}"
    echo "WARP_ADDRESS_V6=${address_v6}"
    echo "WARP_PUBLIC_KEY=${public_key}"
    echo "WARP_ENDPOINT_HOST=${endpoint_host}"
    echo "WARP_ENDPOINT_PORT=${endpoint_port}"
    echo "WARP_MTU=${mtu}"
}

# Generate Xray-compatible WireGuard outbound configuration for WARP
generate_xray_warp_outbound() {
    local config_file="${1:-$WARP_CONFIG_FILE}"
    local output_file="${2:-${WARP_DIR}/warp_outbound.json}"
    
    log_info "Generating Xray-compatible WARP outbound configuration..."
    
    # Parse WARP config
    local warp_vars
    warp_vars=$(parse_warp_config "$config_file")
    
    if [[ -z "$warp_vars" ]]; then
        log_error "Failed to parse WARP config"
        return 1
    fi
    
    # Export variables locally
    eval "$warp_vars"
    
    # Validate required fields
    if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_PUBLIC_KEY" || -z "$WARP_ENDPOINT_HOST" ]]; then
        log_error "Missing required WARP configuration fields"
        return 1
    fi
    
    # Extract IP without CIDR notation for Xray
    local address_v4_ip="${WARP_ADDRESS_V4%/*}"
    local address_v6_ip="${WARP_ADDRESS_V6%/*}"
    
    # Ensure we have at least IPv4
    if [[ -z "$address_v4_ip" ]]; then
        log_error "No IPv4 address found in WARP config"
        return 1
    fi
    
    # Build addresses array
    local addresses_json="\"${address_v4_ip}/32\""
    if [[ -n "$address_v6_ip" ]]; then
        addresses_json+=", \"${address_v6_ip}/128\""
    fi
    
    # Generate Xray WireGuard outbound JSON
    cat > "$output_file" << EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WARP_PRIVATE_KEY}",
    "address": [${addresses_json}],
    "peers": [
      {
        "publicKey": "${WARP_PUBLIC_KEY}",
        "allowedIPs": ["0.0.0.0/0", "::/0"],
        "endpoint": "${WARP_ENDPOINT_HOST}:${WARP_ENDPOINT_PORT}"
      }
    ],
    "mtu": ${WARP_MTU},
    "reserved": [0, 0, 0]
  }
}
EOF
    
    # Validate generated JSON
    if command_exists jq; then
        if ! jq -e '.' "$output_file" &>/dev/null; then
            log_error "Generated WARP outbound JSON is invalid"
            rm -f "$output_file"
            return 1
        fi
    fi
    
    chmod 0600 "$output_file"
    register_file "$output_file"
    
    log_success "Xray WARP outbound config saved to ${output_file}"
    
    # Print the config for verification
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        log_debug "WARP outbound configuration:"
        cat "$output_file"
    fi
}

# Test WARP connectivity
test_warp_connectivity() {
    log_info "Testing WARP connectivity..."
    
    local warp_vars
    warp_vars=$(parse_warp_config "$WARP_CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$warp_vars" ]]; then
        log_warn "Cannot test WARP - config not found"
        return 1
    fi
    
    eval "$warp_vars"
    
    # Check if endpoint is reachable (UDP check is unreliable, so just verify DNS resolves)
    if command_exists dig; then
        if dig +short "$WARP_ENDPOINT_HOST" A &>/dev/null; then
            log_success "WARP endpoint ${WARP_ENDPOINT_HOST} DNS resolves"
            return 0
        fi
    fi
    
    # Try with host command
    if command_exists host; then
        if host "$WARP_ENDPOINT_HOST" &>/dev/null; then
            log_success "WARP endpoint ${WARP_ENDPOINT_HOST} DNS resolves"
            return 0
        fi
    fi
    
    log_warn "Could not verify WARP endpoint DNS resolution"
    return 0  # Don't fail on this
}

# Save WARP configuration summary
save_warp_summary() {
    local summary_file="${WARP_DIR}/warp_summary.txt"
    
    log_info "Saving WARP configuration summary..."
    
    local warp_vars
    warp_vars=$(parse_warp_config "$WARP_CONFIG_FILE" 2>/dev/null)
    
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
# Xray outbound config stored in ${WARP_DIR}/warp_outbound.json
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
            if generate_xray_warp_outbound; then
                save_warp_summary
                test_warp_connectivity
                return 0
            fi
        fi
    fi
    
    # Install wgcf
    if ! command_exists wgcf; then
        if ! install_wgcf; then
            log_error "Failed to install wgcf"
            log_warn "WARP setup failed, Profile 3 will use direct routing"
            return 1
        fi
    fi
    
    # Create WARP directory
    create_dir "$WARP_DIR" "0700"
    
    # Register account
    if ! register_warp_account "$WARP_DIR"; then
        log_error "Failed to register WARP account"
        log_warn "Trying alternative API registration..."
        
        if ! setup_warp_via_api; then
            log_error "WARP setup failed completely"
            return 1
        fi
        return 0
    fi
    
    # Generate config
    if ! generate_warp_config "$WARP_DIR"; then
        log_error "Failed to generate WARP config"
        return 1
    fi
    
    # Generate Xray-compatible outbound
    if ! generate_xray_warp_outbound; then
        log_error "Failed to generate Xray WARP outbound"
        return 1
    fi
    
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

# Alternative: Use warp-reg API for WARP registration (Fallback)
setup_warp_via_api() {
    log_info "Attempting WARP registration via API..."
    
    create_dir "$WARP_DIR" "0700"
    
    # Check if wg command is available
    if ! command_exists wg; then
        log_info "Installing WireGuard tools..."
        apt-get update -qq && apt-get install -y -qq wireguard-tools
    fi
    
    # Generate WireGuard key pair
    local private_key
    local public_key
    
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    
    if [[ -z "$public_key" ]]; then
        log_error "Failed to generate WireGuard keys"
        return 1
    fi
    
    # Call Cloudflare API to register device
    local response
    response=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        --max-time 30 \
        -H "Content-Type: application/json" \
        -H "CF-Client-Version: a-6.11-2223" \
        --data "{\"key\":\"${public_key}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"Linux\",\"serial_number\":\"$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)\"}")
    
    if [[ -z "$response" ]]; then
        log_error "WARP API registration failed - empty response"
        return 1
    fi
    
    # Check for error in response
    if echo "$response" | grep -q '"success":false'; then
        log_error "WARP API registration failed"
        log_debug "Response: $response"
        return 1
    fi
    
    # Parse response (using grep/sed if jq not available)
    local peer_public_key=""
    local endpoint_host="engage.cloudflareclient.com"
    local endpoint_port="2408"
    local address_v4=""
    local address_v6=""
    
    if command_exists jq; then
        peer_public_key=$(echo "$response" | jq -r '.result.config.peers[0].public_key // empty')
        address_v4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4 // empty')
        address_v6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6 // empty')
    else
        # Fallback parsing with grep
        peer_public_key=$(echo "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | head -1)
        address_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)
        address_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)
    fi
    
    if [[ -z "$peer_public_key" || -z "$address_v4" ]]; then
        log_error "Missing required fields in WARP API response"
        log_debug "Response: $response"
        return 1
    fi
    
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
    
    # Generate Xray-compatible outbound
    generate_xray_warp_outbound
    save_warp_summary
}
