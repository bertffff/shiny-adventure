#!/bin/bash
# =============================================================================
# MODULE: adguard.sh - AdGuard Home DNS Server
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# ADGUARD HOME CONFIGURATION
# -----------------------------------------------------------------------------

readonly ADGUARD_DIR="/opt/marzban/adguard"
readonly ADGUARD_CONFIG="${ADGUARD_DIR}/conf/AdGuardHome.yaml"

# Generate bcrypt hash for AdGuard password
generate_bcrypt_hash() {
    local password="$1"
    
    # Use htpasswd if available
    if command_exists htpasswd; then
        htpasswd -nbBC 10 "" "$password" | tr -d ':\n' | sed 's/$2y/$2a/'
        return
    fi
    
    # Use Python as fallback
    if command_exists python3; then
        python3 -c "import bcrypt; print(bcrypt.hashpw(b'${password}', bcrypt.gensalt(10)).decode())" 2>/dev/null && return
    fi
    
    # Use Docker with a Python image as last resort
    docker run --rm python:3-slim python3 -c "
import bcrypt
print(bcrypt.hashpw(b'${password}', bcrypt.gensalt(10)).decode())
" 2>/dev/null
}

# Install htpasswd and bcrypt dependencies
install_bcrypt_deps() {
    log_info "Installing bcrypt dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq apache2-utils python3-pip
    pip3 install bcrypt --break-system-packages 2>/dev/null || pip3 install bcrypt
}

# Create AdGuard Home configuration
create_adguard_config() {
    local username="$1"
    local password="$2"
    local web_port="${3:-3000}"
    local dns_port="${4:-5353}"
    
    log_info "Creating AdGuard Home configuration..."
    
    # Generate bcrypt hash
    local password_hash
    password_hash=$(generate_bcrypt_hash "$password")
    
    if [[ -z "$password_hash" ]]; then
        log_error "Failed to generate password hash"
        return 1
    fi
    
    create_dir "${ADGUARD_DIR}/conf" "0755"
    create_dir "${ADGUARD_DIR}/work" "0755"
    
    cat > "$ADGUARD_CONFIG" << EOF
bind_host: 0.0.0.0
bind_port: ${web_port}
users:
  - name: ${username}
    password: ${password_hash}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: ${dns_port}
  anonymize_client_ip: false
  protection_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  ratelimit: 100
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
  upstream_dns_file: ""
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  all_servers: false
  fastest_addr: true
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
    - 172.16.0.0/12
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: true
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  filtering_enabled: true
  filters_update_interval: 24
  parental_enabled: false
  safesearch_enabled: false
  safebrowsing_enabled: true
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  rewrites: []
  blocked_services: []
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  serve_http3: false
  use_http3_upstreams: false
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 784
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  enabled: true
  file_enabled: true
  interval: 24h
  size_memory: 1000
  ignored: []
statistics:
  enabled: true
  interval: 24h
  ignored: []
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://raw.githubusercontent.com/DandelionSprout/adfilt/master/GameConsoleAdblockList.txt
    name: Game Console Adblock List
    id: 3
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log_file: ""
log_max_backups: 0
log_max_size: 100
log_max_age: 3
log_compress: false
log_localtime: false
verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 24
EOF
    
    chmod 0644 "$ADGUARD_CONFIG"
    register_file "$ADGUARD_CONFIG"
    
    log_success "AdGuard Home configuration created"
}

# Create Docker Compose file for AdGuard Home
create_adguard_compose() {
    local web_port="${1:-3000}"
    local dns_port="${2:-5353}"
    local compose_file="${ADGUARD_DIR}/docker-compose.yml"
    
    log_info "Creating AdGuard Home Docker Compose file..."
    
    cat > "$compose_file" << EOF
version: "3.8"

services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    hostname: adguardhome
    networks:
      - marzban-network
    ports:
      - "${web_port}:${web_port}/tcp"
      - "${dns_port}:${dns_port}/tcp"
      - "${dns_port}:${dns_port}/udp"
    volumes:
      - ${ADGUARD_DIR}/work:/opt/adguardhome/work
      - ${ADGUARD_DIR}/conf:/opt/adguardhome/conf
    cap_add:
      - NET_ADMIN
    environment:
      - TZ=\${TZ:-UTC}

networks:
  marzban-network:
    external: true
EOF
    
    chmod 0644 "$compose_file"
    register_file "$compose_file"
    
    log_success "AdGuard Home Docker Compose file created"
}

# Start AdGuard Home
start_adguard() {
    log_info "Starting AdGuard Home..."
    
    cd "$ADGUARD_DIR"
    
    docker compose up -d
    
    register_rollback "Stop AdGuard Home" "cd '${ADGUARD_DIR}' && docker compose down"
    
    # Wait for AdGuard to be ready
    sleep 5
    
    if docker ps | grep -q adguardhome; then
        log_success "AdGuard Home started"
        return 0
    else
        log_error "AdGuard Home failed to start"
        docker logs adguardhome 2>&1 | tail -20
        return 1
    fi
}

# Check AdGuard Home health
check_adguard_health() {
    local web_port="${1:-3000}"
    
    log_info "Checking AdGuard Home health..."
    
    # Check if container is running
    if ! docker ps | grep -q adguardhome; then
        log_error "AdGuard Home container is not running"
        return 1
    fi
    
    # Check web interface
    if curl -sf "http://127.0.0.1:${web_port}/" -o /dev/null; then
        log_success "AdGuard Home web interface is accessible"
    else
        log_warn "AdGuard Home web interface may not be ready yet"
    fi
    
    # Check DNS
    local dns_port="${2:-5353}"
    if dig @127.0.0.1 -p "$dns_port" google.com +short &>/dev/null; then
        log_success "AdGuard Home DNS is responding"
    else
        log_warn "AdGuard Home DNS may not be ready yet"
    fi
    
    return 0
}

# Get AdGuard internal IP for Marzban configuration
get_adguard_dns_address() {
    local dns_port="${1:-53}"

    # Get container IP in the marzban-network specifically
    local container_ip
    container_ip=$(docker inspect -f '{{.NetworkSettings.Networks.marzban-network.IPAddress}}' adguardhome 2>/dev/null)

    if [[ -n "$container_ip" && "$container_ip" != "<no value>" ]]; then
        echo "${container_ip}:${dns_port}"
    else
        # Fallback: use container name (Docker DNS resolution)
        echo "adguardhome:${dns_port}"
    fi
}

# Main AdGuard setup function
setup_adguard() {
    local username="${1:-admin}"
    local password="${2:-}"
    local web_port="${3:-3000}"
    local dns_port="${4:-5353}"
    
    log_step "Setting up AdGuard Home"
    
    # Generate password if not provided
    if [[ -z "$password" ]]; then
        password=$(generate_password 24)
        log_info "Generated AdGuard password: ${password}"
    fi
    
    # Install bcrypt dependencies
    install_bcrypt_deps
    
    # Create directories
    create_dir "$ADGUARD_DIR" "0755"
    create_dir "${ADGUARD_DIR}/conf" "0755"
    create_dir "${ADGUARD_DIR}/work" "0755"
    
    # Create configuration
    create_adguard_config "$username" "$password" "$web_port" "$dns_port"
    
    # Create Docker Compose file
    create_adguard_compose "$web_port" "$dns_port"
    
    # Ensure Docker network exists
    if ! docker network inspect marzban-network &>/dev/null; then
        log_info "Creating Docker network..."
        docker network create marzban-network
    fi
    
    # Start AdGuard
    start_adguard
    
    # Wait for startup
    log_info "Waiting for AdGuard Home to initialize..."
    sleep 10
    
    # Check health
    check_adguard_health "$web_port" "$dns_port"
    
    # Get DNS address for Marzban
    local dns_address
    dns_address=$(get_adguard_dns_address "$dns_port")
    
    # Save credentials
    local creds_file="${ADGUARD_DIR}/credentials.txt"
    cat > "$creds_file" << EOF
# AdGuard Home Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ================================

Web Interface: http://YOUR_SERVER_IP:${web_port}
Username: ${username}
Password: ${password}

DNS Address (for Marzban): ${dns_address}
EOF
    
    chmod 0600 "$creds_file"
    register_file "$creds_file"
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}AdGuard Home Setup Complete${NC}"
    print_separator
    echo ""
    echo "Web Interface Port: ${web_port}"
    echo "DNS Port: ${dns_port}"
    echo "Username: ${username}"
    echo "Password: ${password}"
    echo ""
    echo "DNS Address for Marzban: ${dns_address}"
    echo ""
    print_separator
    
    log_success "AdGuard Home setup completed"
    
    # Export for use in other modules
    export ADGUARD_DNS="${dns_address}"
    export ADGUARD_USER="$username"
    export ADGUARD_PASS="$password"
    
    echo "ADGUARD_DNS=${dns_address}"
    echo "ADGUARD_USER=${username}"
    echo "ADGUARD_PASS=${password}"
}

# Update AdGuard Home
update_adguard() {
    log_info "Updating AdGuard Home..."
    
    cd "$ADGUARD_DIR"
    
    docker compose pull
    docker compose up -d
    
    log_success "AdGuard Home updated"
}

# Restart AdGuard Home
restart_adguard() {
    log_info "Restarting AdGuard Home..."
    
    cd "$ADGUARD_DIR"
    
    docker compose restart
    
    log_success "AdGuard Home restarted"
}
