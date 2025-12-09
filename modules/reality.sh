#!/bin/bash
# =============================================================================
# MODULE: reality.sh - Reality Protocol Keys Generation
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# REALITY KEYS GENERATION
# -----------------------------------------------------------------------------

readonly KEYS_DIR="/opt/marzban/keys"

# Generate X25519 key pair using multiple methods
generate_x25519_keypair() {
    local private_key=""
    local public_key=""
    
    log_info "Generating X25519 key pair..."
    
    # Method 1: Try using xray (most compatible with Xray)
    if docker image inspect teddysun/xray &>/dev/null || docker pull teddysun/xray &>/dev/null 2>&1; then
        log_debug "Trying xray for key generation"
        local keypair
        keypair=$(timeout 30 docker run --rm teddysun/xray xray x25519 2>/dev/null)
        
        if [[ -n "$keypair" ]]; then
            private_key=$(echo "$keypair" | grep -i "private" | awk -F: '{print $2}' | tr -d ' ')
            public_key=$(echo "$keypair" | grep -i "public" | awk -F: '{print $2}' | tr -d ' ')
        fi
    fi
    
    # Method 2: Try using sing-box
    if [[ -z "$private_key" ]]; then
        if docker image inspect ghcr.io/sagernet/sing-box:latest &>/dev/null || \
           timeout 60 docker pull ghcr.io/sagernet/sing-box:latest &>/dev/null 2>&1; then
            log_debug "Trying sing-box for key generation"
            local keypair
            keypair=$(timeout 30 docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair 2>/dev/null)
            
            if [[ -n "$keypair" ]]; then
                private_key=$(echo "$keypair" | grep -i "private" | awk '{print $NF}')
                public_key=$(echo "$keypair" | grep -i "public" | awk '{print $NF}')
            fi
        fi
    fi
    
    # Method 3: Use openssl and manual conversion
    if [[ -z "$private_key" ]]; then
        log_debug "Using openssl for key generation"
        
        # Generate raw X25519 private key (32 bytes)
        local raw_private
        raw_private=$(openssl genpkey -algorithm X25519 2>/dev/null | \
            openssl pkey -outform DER 2>/dev/null | \
            tail -c 32 | \
            base64 -w 0)
        
        if [[ -n "$raw_private" ]]; then
            private_key="$raw_private"
            
            # For public key, we need to derive it
            # This is a simplified approach - in production, use proper crypto library
            public_key=$(echo -n "$private_key" | base64 -d 2>/dev/null | \
                openssl pkey -inform DER -pubout -outform DER 2>/dev/null | \
                tail -c 32 | \
                base64 -w 0)
        fi
    fi
    
    # Method 4: Use Python with cryptography library
    if [[ -z "$private_key" ]]; then
        log_debug "Trying Python cryptography library"
        
        if python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null; then
            local keypair
            keypair=$(python3 << 'EOF'
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64

private_key = X25519PrivateKey.generate()
public_key = private_key.public_key()

private_bytes = private_key.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
public_bytes = public_key.public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)

print(f"PRIVATE_KEY={base64.b64encode(private_bytes).decode()}")
print(f"PUBLIC_KEY={base64.b64encode(public_bytes).decode()}")
EOF
)
            if [[ -n "$keypair" ]]; then
                private_key=$(echo "$keypair" | grep "PRIVATE_KEY" | cut -d= -f2)
                public_key=$(echo "$keypair" | grep "PUBLIC_KEY" | cut -d= -f2)
            fi
        fi
    fi
    
    # Validate keys
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "Failed to generate X25519 key pair with any method"
        return 1
    fi
    
    # Basic validation - keys should be base64 encoded 32 bytes
    local private_len=${#private_key}
    local public_len=${#public_key}
    
    if [[ $private_len -lt 40 || $public_len -lt 40 ]]; then
        log_warn "Generated keys may be invalid (length check failed)"
    fi
    
    echo "PRIVATE_KEY=${private_key}"
    echo "PUBLIC_KEY=${public_key}"
}

# Generate Reality Short ID (8 hex characters)
generate_reality_short_id() {
    local short_id=""
    
    if command_exists openssl; then
        short_id=$(openssl rand -hex 4 2>/dev/null)
    fi
    
    if [[ -z "$short_id" ]]; then
        # Fallback using /dev/urandom
        short_id=$(head -c 4 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || \
                   printf '%08x' $((RANDOM * RANDOM % 4294967296)))
    fi
    
    echo "$short_id"
}

# Generate multiple Short IDs
generate_reality_short_ids() {
    local count="${1:-3}"
    local short_ids=()
    
    for ((i = 0; i < count; i++)); do
        local id
        id=$(generate_reality_short_id)
        if [[ -n "$id" ]]; then
            short_ids+=("$id")
        fi
    done
    
    # Return as comma-separated list
    local IFS=','
    echo "${short_ids[*]}"
}

# Generate UUID for VLESS
generate_uuid() {
    local uuid=""
    
    if command_exists uuidgen; then
        uuid=$(uuidgen)
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        # Fallback: generate UUID v4 manually
        uuid=$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
            $((RANDOM)) $((RANDOM)) \
            $((RANDOM)) \
            $((RANDOM & 0x0fff | 0x4000)) \
            $((RANDOM & 0x3fff | 0x8000)) \
            $((RANDOM)) $((RANDOM)) $((RANDOM)))
    fi
    
    echo "$uuid"
}

# Save keys to file
save_keys() {
    local keys_file="${KEYS_DIR}/reality_keys.env"
    local private_key="$1"
    local public_key="$2"
    local short_ids="$3"
    
    create_dir "$KEYS_DIR" "0700"
    
    cat > "$keys_file" << EOF
# Reality Keys - Generated $(date '+%Y-%m-%d %H:%M:%S')
# KEEP THIS FILE SECURE!

REALITY_PRIVATE_KEY="${private_key}"
REALITY_PUBLIC_KEY="${public_key}"
REALITY_SHORT_IDS="${short_ids}"
EOF
    
    chmod 0600 "$keys_file"
    register_file "$keys_file"
    
    log_success "Keys saved to ${keys_file}"
}

# Load existing keys
load_keys() {
    local keys_file="${KEYS_DIR}/reality_keys.env"
    
    if [[ -f "$keys_file" ]]; then
        source "$keys_file"
        
        # Validate loaded keys
        if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && -n "$REALITY_SHORT_IDS" ]]; then
            log_info "Loaded existing Reality keys"
            return 0
        fi
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
    private_key=$(echo "$keypair" | grep "PRIVATE_KEY" | cut -d= -f2)
    public_key=$(echo "$keypair" | grep "PUBLIC_KEY" | cut -d= -f2)
    
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "Failed to parse generated keys"
        return 1
    fi
    
    log_success "X25519 key pair generated"
    
    # Generate Short IDs (3 different ones)
    log_info "Generating Short IDs..."
    local short_ids
    short_ids=$(generate_reality_short_ids 3)
    
    if [[ -z "$short_ids" ]]; then
        log_error "Failed to generate Short IDs"
        return 1
    fi
    
    log_success "Short IDs generated: ${short_ids}"
    
    # Save keys
    save_keys "$private_key" "$public_key" "$short_ids"
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}Reality Keys Generated Successfully${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}Private Key (SERVER ONLY - keep secret!):${NC}"
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
    local resolved=false
    
    if command_exists dig; then
        if dig +short "$sni" A 2>/dev/null | grep -qE '^[0-9]+\.'; then
            resolved=true
        fi
    elif command_exists host; then
        if host "$sni" 2>/dev/null | grep -q "has address"; then
            resolved=true
        fi
    fi
    
    if [[ "$resolved" != "true" ]]; then
        log_warn "SNI ${sni} does not resolve. This may cause issues."
        return 1
    fi
    
    # Check if HTTPS is accessible
    if ! curl -sf --connect-timeout 5 --max-time 10 "https://${sni}" -o /dev/null 2>/dev/null; then
        log_warn "Cannot reach https://${sni}. Reality handshake may fail."
        return 1
    fi
    
    # Check TLS version
    local tls_version=""
    if command_exists openssl; then
        tls_version=$(echo | timeout 10 openssl s_client -connect "${sni}:443" -tls1_3 2>/dev/null | \
            grep -oP "Protocol\s*:\s*\K\S+" || true)
    fi
    
    if [[ "$tls_version" == "TLSv1.3" ]]; then
        log_success "SNI ${sni} supports TLS 1.3 (required for Reality)"
    else
        log_warn "SNI ${sni} may not support TLS 1.3. Reality may not work properly."
    fi
    
    return 0
}

# Validate list of SNIs
validate_sni_list() {
    local snis=("$@")
    local valid_snis=()
    
    for sni in "${snis[@]}"; do
        if verify_reality_sni "$sni"; then
            valid_snis+=("$sni")
        else
            log_warn "SNI $sni failed validation, skipping"
        fi
    done
    
    if [[ ${#valid_snis[@]} -eq 0 ]]; then
        log_error "No valid SNIs found!"
        return 1
    fi
    
    echo "${valid_snis[@]}"
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
