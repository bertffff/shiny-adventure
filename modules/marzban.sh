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
        log_info "Generated admin password"
    fi
    
    # Generate secret key
    local secret_key
    secret_key=$(generate_alphanum 32)
    
    cat > "$MARZBAN_ENV" << EOF
# Marzban Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# =====================================

# Admin Credentials
SUDO_USERNAME=${admin_user}
SUDO_PASSWORD=${admin_pass}

# Security
SECRET_KEY=${secret_key}

# Database
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3

# Dashboard
DASHBOARD_PATH=/dashboard

# Subscription
SUBSCRIPTION_URL_PREFIX=https://${sub_domain}
SUB_PROFILE_TITLE=VPN

# Xray Executable (Sing-box compatibility)
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_EXECUTABLE_PATH=/usr/local/bin/xray

# UV Thread Pool
UVICORN_HOST=0.0.0.0
UVICORN_PORT=8000

# SSL/TLS
UVICORN_SSL_CERTFILE=/var/lib/marzban/ssl/${panel_domain}.crt
UVICORN_SSL_KEYFILE=/var/lib/marzban/ssl/${panel_domain}.key

# Docs
DOCS=true
DEBUG=false

# Custom templates
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/marzban/templates/

# Webhook (optional)
# WEBHOOK_ADDRESS=
# WEBHOOK_SECRET=

# Node/Cluster support
# XRAY_SUBSCRIPTION_URL_PREFIX=

# Telegram Bot (optional)
# TELEGRAM_API_TOKEN=
# TELEGRAM_ADMIN_ID=
# TELEGRAM_PROXY_URL=

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
    local vpn_ports=("${@:2}")
    
    log_info "Creating Marzban Docker Compose configuration..."
    
    # Build ports section for VPN
    local ports_section=""
    for port in "${vpn_ports[@]}"; do
        ports_section+="      - \"${port}:${port}/tcp\"\n"
        ports_section+="      - \"${port}:${port}/udp\"\n"
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
    local config_file="${MARZBAN_DIR}/xray_config.json"
    
    log_info "Creating base Xray configuration..."
    
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
    
    # Also copy to /var/lib/marzban
    mkdir -p /var/lib/marzban
    cp "$config_file" /var/lib/marzban/xray_config.json
    
    register_file "$config_file"
    register_file "/var/lib/marzban/xray_config.json"
    
    log_success "Base Xray configuration created"
}

# Copy SSL certificates to Marzban directory
setup_marzban_ssl() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    
    log_info "Setting up SSL certificates for Marzban..."
    
    # Создаём обе директории
    local marzban_ssl_dir="${MARZBAN_DIR}/ssl"
    local varlib_ssl_dir="/var/lib/marzban/ssl"
    
    create_dir "$marzban_ssl_dir" "0700"
    mkdir -p "$varlib_ssl_dir"
    chmod 0700 "$varlib_ssl_dir"
    
    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        log_error "SSL certificate files not found"
        return 1
    fi
    
    # Копируем в обе локации
    for ssl_dir in "$marzban_ssl_dir" "$varlib_ssl_dir"; do
        local target_cert="${ssl_dir}/${domain}.crt"
        local target_key="${ssl_dir}/${domain}.key"
        
        cp "$cert_file" "$target_cert"
        chmod 0644 "$target_cert"
        
        cp "$key_file" "$target_key"
        chmod 0600 "$target_key"
        
        log_info "SSL certificates copied to ${ssl_dir}"
    done
    
    log_success "SSL certificates configured for Marzban"
}

# Start Marzban
start_marzban() {
    log_info "Starting Marzban..."
    
    cd "$MARZBAN_DIR"
    
    docker compose up -d
    
    register_rollback "Stop Marzban" "cd '${MARZBAN_DIR}' && docker compose down"
    
    log_success "Marzban containers started"
}

# Wait for Marzban to be ready
wait_for_marzban() {
    local panel_port="${1:-8443}"
    local timeout="${2:-120}"
    
    log_info "Waiting for Marzban to be ready..."
    
    local elapsed=0
    local interval=5
    
    while [[ $elapsed -lt $timeout ]]; do
        # Проверяем HTTP код ответа
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            "https://127.0.0.1:${panel_port}/dashboard/" \
            2>/dev/null || echo "000")
        
        # 401/422 означают что API работает (просто неверные credentials)
        if [[ "$http_code" == "401" || "$http_code" == "422" || "$http_code" == "200" ]]; then
            log_success "Marzban API is responding (HTTP ${http_code})"
            return 0
        fi
        
        if ! docker ps | grep -q marzban; then
            log_error "Marzban container stopped unexpectedly"
            docker logs marzban 2>&1 | tail -30
            return 1
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
        log_debug "Still waiting... (${elapsed}/${timeout}s)"
    done
    
    log_error "Timeout waiting for Marzban"
    docker logs marzban 2>&1 | tail -30
    return 1
}

# Get Marzban admin token
get_marzban_token() {
    local panel_url="$1"
    local username="$2"
    local password="$3"
    
    local response
    response=$(curl -sf -k "${panel_url}/api/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data "username=${username}&password=${password}")
    
    if [[ -z "$response" ]]; then
        log_error "Failed to get Marzban token"
        return 1
    fi
    
    local token
    token=$(echo "$response" | jq -r '.access_token')
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Invalid token response: ${response}"
        return 1
    fi
    
    echo "$token"
}

# Check Marzban health
check_marzban_health() {
    local panel_port="${1:-8443}"
    
    log_info "Checking Marzban health..."
    
    # Check container status
    if ! docker ps | grep -q marzban; then
        log_error "Marzban container is not running"
        return 1
    fi
    
    # Check API endpoint
    local http_code
    http_code=$(curl -sf -k -o /dev/null -w "%{http_code}" "https://127.0.0.1:${panel_port}/dashboard/" 2>/dev/null)
    
    if [[ "$http_code" == "200" || "$http_code" == "401" || "$http_code" == "422" ]]; then
        log_success "Marzban API is healthy (HTTP ${http_code})"
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
    create_marzban_env "$admin_user" "$admin_pass" "$panel_domain" "$sub_domain" "$panel_port" "$dns_server" "$ssl_cert" "$ssl_key"
    
    # Setup SSL
    setup_marzban_ssl "$panel_domain" "$ssl_cert" "$ssl_key"
    
    # Create Docker Compose
    create_marzban_compose "$panel_port" "${vpn_ports[@]}"
    
    # Create base Xray config
    create_xray_base_config
    
    # Start Marzban
    start_marzban
    
    # Wait for Marzban to be ready
    wait_for_marzban "$panel_port"
    
    # Check health
    check_marzban_health "$panel_port"
    
    log_success "Marzban installation completed"
}

# Update Marzban
update_marzban() {
    log_info "Updating Marzban..."
    
    cd "$MARZBAN_DIR"
    
    docker compose pull
    docker compose up -d
    
    log_success "Marzban updated"
}

# Restart Marzban
restart_marzban() {
    log_info "Restarting Marzban..."
    
    cd "$MARZBAN_DIR"
    
    docker compose restart marzban
    
    log_success "Marzban restarted"
}

# Show Marzban logs
show_marzban_logs() {
    local lines="${1:-50}"
    
    docker logs marzban --tail "$lines"
}
