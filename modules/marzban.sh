#!/bin/bash
# =============================================================================
# MODULE: marzban.sh - Marzban Panel Installation & Configuration
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# MARZBAN INSTALLATION
# -----------------------------------------------------------------------------

readonly MARZBAN_DIR="/opt/marzban"
readonly MARZBAN_ENV="${MARZBAN_DIR}/.env"
readonly MARZBAN_COMPOSE="${MARZBAN_DIR}/docker-compose.yml"

# Create Marzban directory structure
create_marzban_dirs() {
    log_info "Creating Marzban directory structure..."
    
    local dirs=(
        "$MARZBAN_DIR"
        "${MARZBAN_DIR}/data"
        "${MARZBAN_DIR}/logs"
        "${MARZBAN_DIR}/ssl"
        "${MARZBAN_DIR}/templates"
        "${MARZBAN_DIR}/xray-config"
        "/var/lib/marzban"
        "/var/lib/marzban/logs"
        "/var/lib/marzban/ssl"
        "/var/lib/marzban/templates"
    )
    
    for dir in "${dirs[@]}"; do
        create_dir "$dir" "0755"
    done
    
    log_success "Marzban directories created"
}

# Create Marzban .env configuration
create_marzban_env() {
    local admin_user="$1"
    local admin_pass="$2"
    local panel_domain="$3"
    local sub_domain="$4"
    local panel_port="$5"
    local dns_server="$6"
    local ssl_cert="$7"
    local ssl_key="$8"
    
    log_info "Creating Marzban environment configuration..."
    
    # Generate admin password if not provided
    if [[ -z "$admin_pass" ]]; then
        admin_pass=$(generate_password 24)
        if [[ -z "$admin_pass" ]]; then
            log_error "Failed to generate admin password"
            return 1
        fi
        log_info "Generated admin password"
    fi
    
    # Generate secret key
    local secret_key
    secret_key=$(generate_alphanum 32)
    
    if [[ -z "$secret_key" ]]; then
        log_error "Failed to generate secret key"
        return 1
    fi
    
    # Escape values for .env file
    local escaped_pass
    escaped_pass=$(printf '%s' "$admin_pass" | sed 's/[&/\]/\\&/g')
    
    cat > "$MARZBAN_ENV" << EOF
# Marzban Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# =====================================

# Admin Credentials
SUDO_USERNAME=${admin_user}
SUDO_PASSWORD=${escaped_pass}

# Security
SECRET_KEY=${secret_key}

# Database
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3

# Dashboard
DASHBOARD_PATH=/dashboard

# Subscription
SUBSCRIPTION_URL_PREFIX=https://${sub_domain}
SUB_PROFILE_TITLE=VPN

# Xray Configuration
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_EXECUTABLE_PATH=/usr/local/bin/xray

# Server
UVICORN_HOST=0.0.0.0
UVICORN_PORT=8000

# SSL/TLS
UVICORN_SSL_CERTFILE=/var/lib/marzban/ssl/${panel_domain}.crt
UVICORN_SSL_KEYFILE=/var/lib/marzban/ssl/${panel_domain}.key

# Documentation
DOCS=true
DEBUG=false

# Custom templates
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/marzban/templates/

# JWT
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440

# DNS Configuration (AdGuard)
XRAY_DNS_SERVERS=${dns_server}

# Timezone
TZ=${TZ:-Europe/Amsterdam}
EOF
    
    chmod 0600 "$MARZBAN_ENV"
    register_file "$MARZBAN_ENV"
    
    # Save admin credentials separately
    local creds_file="${MARZBAN_DIR}/admin_credentials.txt"
    cat > "$creds_file" << EOF
# Marzban Admin Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# KEEP THIS FILE SECURE!
# =====================================

Panel URL: https://${panel_domain}:${panel_port}/dashboard
Username: ${admin_user}
Password: ${admin_pass}
EOF
    
    chmod 0600 "$creds_file"
    register_file "$creds_file"
    
    log_success "Marzban environment configuration created"
    
    # Export for other modules
    export MARZBAN_ADMIN_USER="$admin_user"
    export MARZBAN_ADMIN_PASS="$admin_pass"
    
    echo "MARZBAN_ADMIN_USER=${admin_user}"
    echo "MARZBAN_ADMIN_PASS=${admin_pass}"
}

# Create Marzban Docker Compose file
create_marzban_compose() {
    local panel_port="$1"
    shift
    local vpn_ports=("$@")
    
    log_info "Creating Marzban Docker Compose configuration..."
    
    # Build ports section for VPN
    local ports_section=""
    for port in "${vpn_ports[@]}"; do
        if [[ -n "$port" ]]; then
            ports_section+="      - \"${port}:${port}/tcp\"\n"
            ports_section+="      - \"${port}:${port}/udp\"\n"
        fi
    done
    
    cat > "$MARZBAN_COMPOSE" << EOF
version: "3.8"

services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: unless-stopped
    env_file: .env
    networks:
      - marzban-network
    ports:
      - "${panel_port}:8000/tcp"
$(echo -e "$ports_section")
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - ${MARZBAN_DIR}/ssl:/var/lib/marzban/ssl:ro
      - ${MARZBAN_DIR}/templates:/var/lib/marzban/templates:ro
      - ${MARZBAN_DIR}/logs:/var/lib/marzban/logs
    environment:
      - TZ=\${TZ:-UTC}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8000/api/system"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

networks:
  marzban-network:
    external: true
EOF
    
    chmod 0644 "$MARZBAN_COMPOSE"
    register_file "$MARZBAN_COMPOSE"
    
    log_success "Marzban Docker Compose configuration created"
}

# Create base Xray configuration (will be extended via API)
create_xray_base_config() {
    local config_file="/var/lib/marzban/xray_config.json"
    
    log_info "Creating base Xray configuration..."
    
    # Ensure directory exists
    mkdir -p /var/lib/marzban/logs
    
    cat > "$config_file" << 'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/marzban/logs/access.log",
    "error": "/var/lib/marzban/logs/error.log"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
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
    }
  ],
  "outbounds": [
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
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-inbound"],
        "outboundTag": "api"
      }
    ]
  }
}
EOF
    
    chmod 0644 "$config_file"
    
    # Also copy to Marzban directory for reference
    cp "$config_file" "${MARZBAN_DIR}/xray_config.json"
    
    register_file "$config_file"
    register_file "${MARZBAN_DIR}/xray_config.json"
    
    log_success "Base Xray configuration created"
}

# Copy SSL certificates to Marzban directory
setup_marzban_ssl() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    
    log_info "Setting up SSL certificates for Marzban..."
    
    # Create SSL directories
    local marzban_ssl_dir="${MARZBAN_DIR}/ssl"
    local varlib_ssl_dir="/var/lib/marzban/ssl"
    
    create_dir "$marzban_ssl_dir" "0700"
    mkdir -p "$varlib_ssl_dir"
    chmod 0700 "$varlib_ssl_dir"
    
    # Verify source files exist
    if [[ ! -f "$cert_file" ]]; then
        log_error "SSL certificate file not found: ${cert_file}"
        return 1
    fi
    
    if [[ ! -f "$key_file" ]]; then
        log_error "SSL key file not found: ${key_file}"
        return 1
    fi
    
    # Copy to both locations
    for ssl_dir in "$marzban_ssl_dir" "$varlib_ssl_dir"; do
        local target_cert="${ssl_dir}/${domain}.crt"
        local target_key="${ssl_dir}/${domain}.key"
        
        # Only copy if source and target are different
        if [[ "$(realpath "$cert_file" 2>/dev/null)" != "$(realpath "$target_cert" 2>/dev/null)" ]]; then
            cp "$cert_file" "$target_cert"
        fi
        chmod 0644 "$target_cert"
        
        if [[ "$(realpath "$key_file" 2>/dev/null)" != "$(realpath "$target_key" 2>/dev/null)" ]]; then
            cp "$key_file" "$target_key"
        fi
        chmod 0600 "$target_key"
        
        log_debug "SSL certificates copied to ${ssl_dir}"
    done
    
    log_success "SSL certificates configured for Marzban"
}

# Start Marzban with timeout
start_marzban() {
    log_info "Starting Marzban..."
    
    cd "$MARZBAN_DIR" || return 1
    
    # Pull image first with timeout
    log_info "Pulling Marzban Docker image..."
    if ! timeout 600 docker compose pull 2>/dev/null; then
        log_warn "Docker pull timed out, trying to start anyway..."
    fi
    
    # Start containers with timeout
    if ! timeout 120 docker compose up -d; then
        log_error "Failed to start Marzban containers"
        return 1
    fi
    
    register_rollback "Stop Marzban" "cd '${MARZBAN_DIR}' && docker compose down" "normal"
    
    log_success "Marzban containers started"
}

# Wait for Marzban to be ready
wait_for_marzban() {
    local panel_port="${1:-8443}"
    local timeout="${2:-180}"
    
    log_info "Waiting for Marzban to be ready (timeout: ${timeout}s)..."
    
    local elapsed=0
    local interval=5
    
    while [[ $elapsed -lt $timeout ]]; do
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^marzban$"; then
            log_error "Marzban container stopped unexpectedly"
            docker logs marzban 2>&1 | tail -30
            return 1
        fi
        
        # Check HTTP response code
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            "https://127.0.0.1:${panel_port}/api/system" \
            --max-time 10 2>/dev/null || echo "000")
        
        # 200 = success, 401/422 = API working (auth required)
        if [[ "$http_code" == "200" || "$http_code" == "401" || "$http_code" == "422" ]]; then
            log_success "Marzban API is responding (HTTP ${http_code})"
            return 0
        fi
        
        # Also try dashboard endpoint
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            "https://127.0.0.1:${panel_port}/dashboard/" \
            --max-time 10 2>/dev/null || echo "000")
        
        if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
            log_success "Marzban dashboard is responding (HTTP ${http_code})"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
        log_debug "Still waiting... (${elapsed}/${timeout}s, last HTTP code: ${http_code})"
    done
    
    log_error "Timeout waiting for Marzban to start"
    log_error "Container logs:"
    docker logs marzban 2>&1 | tail -50
    return 1
}

# Get Marzban admin token
get_marzban_token() {
    local panel_url="$1"
    local username="$2"
    local password="$3"
    
    log_debug "Getting Marzban API token..."
    
    local response
    response=$(curl -sf -k "${panel_url}/api/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=${username}" \
        --data-urlencode "password=${password}" \
        --max-time 30 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        log_error "Failed to get Marzban token - empty response"
        return 1
    fi
    
    local token
    if command_exists jq; then
        token=$(echo "$response" | jq -r '.access_token // empty')
    else
        token=$(echo "$response" | grep -oP '"access_token"\s*:\s*"\K[^"]+')
    fi
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Invalid token response"
        log_debug "Response: ${response}"
        return 1
    fi
    
    echo "$token"
}

# Check Marzban health
check_marzban_health() {
    local panel_port="${1:-8443}"
    
    log_info "Checking Marzban health..."
    
    # Check container status
    local container_status
    container_status=$(docker inspect --format='{{.State.Status}}' marzban 2>/dev/null || echo "not found")
    
    if [[ "$container_status" != "running" ]]; then
        log_error "Marzban container status: ${container_status}"
        return 1
    fi
    
    log_debug "Container status: ${container_status}"
    
    # Check API endpoint
    local http_code
    http_code=$(curl -sf -k -o /dev/null -w "%{http_code}" \
        "https://127.0.0.1:${panel_port}/api/system" \
        --max-time 10 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        log_success "Marzban API is healthy"
        return 0
    elif [[ "$http_code" == "401" || "$http_code" == "422" ]]; then
        log_success "Marzban API is responding (auth required)"
        return 0
    else
        log_warn "Marzban API returned HTTP ${http_code}"
        return 1
    fi
}

# Main Marzban installation function
install_marzban() {
    local admin_user="$1"
    local admin_pass="$2"
    local panel_domain="$3"
    local sub_domain="$4"
    local panel_port="$5"
    local dns_server="$6"
    local ssl_cert="$7"
    local ssl_key="$8"
    shift 8
    local vpn_ports=("$@")
    
    log_step "Installing Marzban Panel"
    
    # Create directory structure
    create_marzban_dirs
    
    # Create environment configuration
    local env_output
    env_output=$(create_marzban_env "$admin_user" "$admin_pass" "$panel_domain" "$sub_domain" \
        "$panel_port" "$dns_server" "$ssl_cert" "$ssl_key")
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create Marzban environment"
        return 1
    fi
    
    # Parse output for credentials
    eval "$(echo "$env_output" | grep -E '^MARZBAN_ADMIN')"
    
    # Setup SSL
    if ! setup_marzban_ssl "$panel_domain" "$ssl_cert" "$ssl_key"; then
        log_error "Failed to setup SSL for Marzban"
        return 1
    fi
    
    # Create Docker Compose
    create_marzban_compose "$panel_port" "${vpn_ports[@]}"
    
    # Create base Xray config
    create_xray_base_config
    
    # Start Marzban
    if ! start_marzban; then
        log_error "Failed to start Marzban"
        return 1
    fi
    
    # Wait for Marzban to be ready
    if ! wait_for_marzban "$panel_port" 180; then
        log_error "Marzban did not start properly"
        return 1
    fi
    
    # Final health check
    if ! check_marzban_health "$panel_port"; then
        log_warn "Marzban health check failed, but container is running"
    fi
    
    log_success "Marzban installation completed"
}

# Update Marzban
update_marzban() {
    log_info "Updating Marzban..."
    
    cd "$MARZBAN_DIR" || return 1
    
    # Backup current config
    backup_file "${MARZBAN_DIR}/.env"
    
    timeout 300 docker compose pull || log_warn "Pull timed out"
    timeout 120 docker compose up -d
    
    log_success "Marzban updated"
}

# Restart Marzban
restart_marzban() {
    log_info "Restarting Marzban..."
    
    cd "$MARZBAN_DIR" || return 1
    
    docker compose restart marzban
    
    sleep 5
    
    log_success "Marzban restarted"
}

# Show Marzban logs
show_marzban_logs() {
    local lines="${1:-50}"
    
    docker logs marzban --tail "$lines" 2>&1
}

# Get Marzban status
get_marzban_status() {
    echo "=== Marzban Status ==="
    docker ps --filter "name=marzban" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "=== Recent Logs ==="
    docker logs marzban --tail 10 2>&1
}
