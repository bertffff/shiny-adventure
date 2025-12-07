#!/bin/bash
# =============================================================================
# MODULE: marzban_api.sh - Marzban API Integration for Inbound Configuration
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# MARZBAN API FUNCTIONS
# -----------------------------------------------------------------------------

# Global variables for API access
MARZBAN_API_URL=""
MARZBAN_API_TOKEN=""

# Initialize API access
init_marzban_api() {
    local panel_url="$1"
    local username="$2"
    local password="$3"
    
    MARZBAN_API_URL="$panel_url"
    
    log_info "Authenticating with Marzban API..."
    
    local response
    response=$(curl -sf -k "${panel_url}/api/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data "username=${username}&password=${password}")
    
    if [[ -z "$response" ]]; then
        log_error "Failed to authenticate with Marzban API"
        return 1
    fi
    
    MARZBAN_API_TOKEN=$(echo "$response" | jq -r '.access_token')
    
    if [[ -z "$MARZBAN_API_TOKEN" || "$MARZBAN_API_TOKEN" == "null" ]]; then
        log_error "Failed to get access token"
        return 1
    fi
    
    log_success "Successfully authenticated with Marzban API"
    export MARZBAN_API_TOKEN
}

# Make authenticated API request
marzban_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local curl_args=(
        -sf
        -k
        -X "$method"
        -H "Authorization: Bearer ${MARZBAN_API_TOKEN}"
        -H "Content-Type: application/json"
    )
    
    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi
    
    curl "${curl_args[@]}" "${MARZBAN_API_URL}${endpoint}"
}

# Get current system settings
get_system_settings() {
    log_info "Fetching current system settings..."
    
    local response
    response=$(marzban_api_request "GET" "/api/system")
    
    if [[ -n "$response" ]]; then
        echo "$response" | jq '.'
        return 0
    fi
    
    log_error "Failed to get system settings"
    return 1
}

# Get current inbounds
get_inbounds() {
    log_info "Fetching current inbounds..."
    
    local response
    response=$(marzban_api_request "GET" "/api/inbounds")
    
    if [[ -n "$response" ]]; then
        echo "$response" | jq '.'
        return 0
    fi
    
    return 1
}

# Update system inbound configuration via hosts
update_hosts_config() {
    local config_json="$1"
    
    log_info "Updating hosts configuration..."
    
    local response
    response=$(marzban_api_request "PUT" "/api/hosts" "$config_json")
    
    if [[ -n "$response" ]]; then
        log_success "Hosts configuration updated"
        return 0
    fi
    
    log_error "Failed to update hosts configuration"
    return 1
}

# Create VLESS Reality inbound configuration JSON for Marzban
# This creates the inbound settings that will be added to xray config
generate_vless_reality_inbound() {
    local tag="$1"
    local port="$2"
    local sni="$3"
    local private_key="$4"
    local short_ids="$5"
    local fingerprint="${6:-chrome}"
    
    # Convert comma-separated short_ids to JSON array
    local short_ids_json
    short_ids_json=$(echo "$short_ids" | tr ',' '\n' | jq -R . | jq -s .)
    
    cat << EOF
{
  "tag": "${tag}",
  "listen": "0.0.0.0",
  "port": ${port},
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "tcpSettings": {},
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "${sni}:443",
      "xver": 0,
      "serverNames": ["${sni}"],
      "privateKey": "${private_key}",
      "shortIds": ${short_ids_json},
      "fingerprint": "${fingerprint}"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
}

# Validate and read WARP outbound configuration
# Returns valid JSON or empty string
read_warp_outbound() {
    local warp_outbound_file="$1"
    
    # Check if file exists and is not empty
    if [[ ! -f "$warp_outbound_file" ]]; then
        log_warn "WARP outbound file not found: ${warp_outbound_file}" >&2
        echo ""
        return 1
    fi
    
    if [[ ! -s "$warp_outbound_file" ]]; then
        log_warn "WARP outbound file is empty: ${warp_outbound_file}" >&2
        echo ""
        return 1
    fi
    
    # Read and validate JSON
    local warp_content
    warp_content=$(cat "$warp_outbound_file")
    
    # Validate JSON structure
    if ! echo "$warp_content" | jq -e '.' &>/dev/null; then
        log_warn "WARP outbound file contains invalid JSON" >&2
        echo ""
        return 1
    fi
    
    # Validate required fields for WireGuard outbound
    local outbound_type
    outbound_type=$(echo "$warp_content" | jq -r '.protocol // empty')
    
    if [[ -z "$outbound_type" ]]; then
        log_warn "WARP outbound missing 'type' field" >&2
        echo ""
        return 1
    fi
    
    # Check for required WireGuard fields
    local private_key
    private_key=$(echo "$warp_content" | jq -r '.private_key // empty')
    
    if [[ -z "$private_key" ]]; then
        log_warn "WARP outbound missing 'private_key' field" >&2
        echo ""
        return 1
    fi
    
    log_info "WARP outbound configuration validated successfully" >&2
    echo "$warp_content"
    return 0
}

# Generate full xray configuration with all profiles
generate_full_xray_config() {
    local private_key="$1"
    local short_ids="$2"
    local profile1_port="$3"
    local profile1_sni="$4"
    local profile2_port="$5"
    local profile2_sni="$6"
    local profile3_port="$7"
    local profile3_sni="$8"
    local warp_outbound_file="$9"
    
    log_info "Generating full Xray configuration..." >&2
    
    # Read and validate WARP outbound
    local warp_outbound=""
    local warp_routing_rule=""
    
    if [[ -n "$warp_outbound_file" ]]; then
        warp_outbound=$(read_warp_outbound "$warp_outbound_file")
    fi
    
    # Build outbounds section
    local outbounds_json=""
    if [[ -n "$warp_outbound" ]]; then
        log_info "Including WARP outbound in configuration" >&2
        outbounds_json=$(cat << EOF
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    },
    ${warp_outbound}
EOF
)
        # Add WARP routing rule
        warp_routing_rule=$(cat << 'EOF'
      {
        "type": "field",
        "inboundTag": ["VLESS_REALITY_WARP"],
        "outboundTag": "warp-out"
      },
EOF
)
    else
        log_warn "WARP outbound not available, Profile 3 will use direct routing" >&2
        outbounds_json=$(cat << EOF
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
EOF
)
        warp_routing_rule=""
    fi
    
    # Convert short_ids to JSON array
    local short_ids_json
    short_ids_json=$(echo "$short_ids" | tr ',' '\n' | jq -R . | jq -s .)
    
    # Generate the full configuration
    cat << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/marzban/logs/access.log",
    "error": "/var/lib/marzban/logs/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api-inbound",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "VLESS_REALITY_WHITELIST",
      "listen": "0.0.0.0",
      "port": ${profile1_port},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile1_sni}:443",
          "xver": 0,
          "serverNames": ["${profile1_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "VLESS_REALITY_STANDARD",
      "listen": "0.0.0.0",
      "port": ${profile2_port},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile2_sni}:443",
          "xver": 0,
          "serverNames": ["${profile2_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "VLESS_REALITY_WARP",
      "listen": "0.0.0.0",
      "port": ${profile3_port},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile3_sni}:443",
          "xver": 0,
          "serverNames": ["${profile3_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
${outbounds_json}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-inbound"],
        "outboundTag": "api"
      },
${warp_routing_rule}
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
}

# Apply xray configuration
apply_xray_config() {
    local config_json="$1"
    local config_file="${2:-/var/lib/marzban/xray_config.json}"
    
    log_info "Applying Xray configuration..."
    
    # Validate JSON before applying
    if ! echo "$config_json" | jq '.' &>/dev/null; then
        log_error "Invalid JSON configuration"
        log_error "JSON validation error:"
        echo "$config_json" | jq '.' 2>&1 | head -20
        return 1
    fi
    
    # Additional validation: check for empty outbound types
    local empty_types
    empty_types=$(echo "$config_json" | jq -r '.outbounds[]? | select(.protocol == "" or .protocol == null) | .tag // "unknown"' 2>/dev/null)
    if [[ -n "$empty_types" ]]; then
        log_error "Found outbounds with empty type: ${empty_types}"
        return 1
    fi
    
    # Backup existing config
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Write new config with proper formatting
    echo "$config_json" | jq '.' > "$config_file"
    chmod 0644 "$config_file"
    
    # Also save to Marzban directory
    local marzban_config="${MARZBAN_DIR:-/opt/marzban}/xray_config.json"
    echo "$config_json" | jq '.' > "$marzban_config"
    chmod 0644 "$marzban_config"
    
    log_success "Xray configuration applied to ${config_file}"
}

# Create inbounds host mapping for Marzban
create_hosts_mapping() {
    local server_ip="$1"
    local public_key="$2"
    local short_id="$3"
    local profile1_port="$4"
    local profile1_sni="$5"
    local profile1_name="$6"
    local profile2_port="$7"
    local profile2_sni="$8"
    local profile2_name="$9"
    local profile3_port="${10}"
    local profile3_sni="${11}"
    local profile3_name="${12}"
    
    log_info "Creating hosts mapping for Marzban..."
    
    cat << EOF
{
  "VLESS_REALITY_WHITELIST": [
    {
      "remark": "${profile1_name}",
      "address": "${server_ip}",
      "port": ${profile1_port},
      "sni": "${profile1_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "fragment_setting": "",
      "random_user_agent": false,
      "noise_setting": "",
      "weight": 1
    }
  ],
  "VLESS_REALITY_STANDARD": [
    {
      "remark": "${profile2_name}",
      "address": "${server_ip}",
      "port": ${profile2_port},
      "sni": "${profile2_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "fragment_setting": "",
      "random_user_agent": false,
      "noise_setting": "",
      "weight": 1
    }
  ],
  "VLESS_REALITY_WARP": [
    {
      "remark": "${profile3_name}",
      "address": "${server_ip}",
      "port": ${profile3_port},
      "sni": "${profile3_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "fragment_setting": "",
      "random_user_agent": false,
      "noise_setting": "",
      "weight": 1
    }
  ]
}
EOF
}

# Configure all profiles via API
configure_profiles_via_api() {
    local server_ip="$1"
    local panel_url="$2"
    local admin_user="$3"
    local admin_pass="$4"
    local private_key="$5"
    local public_key="$6"
    local short_ids="$7"
    local profile1_port="$8"
    local profile1_sni="$9"
    local profile1_name="${10}"
    local profile2_port="${11}"
    local profile2_sni="${12}"
    local profile2_name="${13}"
    local profile3_port="${14}"
    local profile3_sni="${15}"
    local profile3_name="${16}"
    local warp_outbound_file="${17:-}"
    
    log_step "Configuring VPN Profiles via Marzban API"
    
    # Initialize API
    if ! init_marzban_api "$panel_url" "$admin_user" "$admin_pass"; then
        log_error "Failed to initialize Marzban API"
        return 1
    fi
    
    # Get first short ID
    local first_short_id
    first_short_id=$(echo "$short_ids" | cut -d',' -f1)
    
    # Generate full xray configuration
    log_info "Generating Xray configuration with all profiles..."
    local xray_config
    xray_config=$(generate_full_xray_config \
        "$private_key" \
        "$short_ids" \
        "$profile1_port" \
        "$profile1_sni" \
        "$profile2_port" \
        "$profile2_sni" \
        "$profile3_port" \
        "$profile3_sni" \
        "$warp_outbound_file")
    
    # Validate generated config before applying
    log_info "Validating generated Xray configuration..."
    if ! echo "$xray_config" | jq -e '.' &>/dev/null; then
        log_error "Generated Xray configuration is invalid JSON"
        log_error "Config preview:"
        echo "$xray_config" | head -50
        return 1
    fi
    
    # Apply xray configuration
    if ! apply_xray_config "$xray_config"; then
        log_error "Failed to apply Xray configuration"
        return 1
    fi
    
    # Generate hosts mapping
    log_info "Creating hosts mapping..."
    local hosts_config
    hosts_config=$(create_hosts_mapping \
        "$server_ip" \
        "$public_key" \
        "$first_short_id" \
        "$profile1_port" \
        "$profile1_sni" \
        "$profile1_name" \
        "$profile2_port" \
        "$profile2_sni" \
        "$profile2_name" \
        "$profile3_port" \
        "$profile3_sni" \
        "$profile3_name")
    
    # Update hosts via API
    if ! update_hosts_config "$hosts_config"; then
        log_warn "Failed to update hosts via API. Manual configuration may be required."
    fi
    
    # Restart Marzban to apply changes
    log_info "Restarting Marzban to apply configuration..."
    cd "${MARZBAN_DIR:-/opt/marzban}"
    docker compose restart marzban
    
    # Wait for Marzban to restart
    sleep 10
    
    log_success "VPN profiles configured successfully"
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}VPN Profiles Configuration Complete${NC}"
    print_separator
    echo ""
    echo "Profile 1: ${profile1_name}"
    echo "  - Port: ${profile1_port}"
    echo "  - SNI: ${profile1_sni}"
    echo "  - Protocol: VLESS + Reality + Vision"
    echo "  - Routing: Direct"
    echo ""
    echo "Profile 2: ${profile2_name}"
    echo "  - Port: ${profile2_port}"
    echo "  - SNI: ${profile2_sni}"
    echo "  - Protocol: VLESS + Reality + Vision"
    echo "  - Routing: Direct"
    echo ""
    echo "Profile 3: ${profile3_name}"
    echo "  - Port: ${profile3_port}"
    echo "  - SNI: ${profile3_sni}"
    echo "  - Protocol: VLESS + Reality + Vision"
    if [[ -n "$warp_outbound_file" ]] && [[ -f "$warp_outbound_file" ]]; then
        echo "  - Routing: Via WARP"
    else
        echo "  - Routing: Direct (WARP not configured)"
    fi
    echo ""
    echo "Reality Public Key: ${public_key}"
    echo "Short ID: ${first_short_id}"
    echo ""
    print_separator
}

# Test profile connectivity
test_profile_connectivity() {
    local server_ip="$1"
    local port="$2"
    
    log_info "Testing connectivity to ${server_ip}:${port}..."
    
    if nc -z -w5 "$server_ip" "$port" 2>/dev/null; then
        log_success "Port ${port} is accessible"
        return 0
    else
        log_warn "Port ${port} may not be accessible externally"
        return 1
    fi
}
