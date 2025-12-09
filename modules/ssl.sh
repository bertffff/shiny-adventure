#!/bin/bash
# =============================================================================
# MODULE: ssl.sh - SSL Certificate Management (Let's Encrypt)
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# SSL CERTIFICATE MANAGEMENT
# -----------------------------------------------------------------------------

readonly SSL_DIR="/opt/marzban/ssl"
readonly ACME_DIR="/root/.acme.sh"

# Check if acme.sh is installed
check_acme_installed() {
    if [[ -f "${ACME_DIR}/acme.sh" ]]; then
        log_info "acme.sh is already installed"
        return 0
    fi
    return 1
}

# Install acme.sh
install_acme() {
    log_info "Installing acme.sh..."
    
    # Install socat (required for standalone mode)
    apt-get update -qq
    apt-get install -y -qq socat curl
    
    # Install acme.sh with timeout
    if ! timeout 120 curl -fsSL https://get.acme.sh | sh -s email="${SSL_EMAIL:-admin@example.com}"; then
        log_error "Failed to install acme.sh"
        return 1
    fi
    
    # Reload shell environment
    if [[ -f "${ACME_DIR}/acme.sh.env" ]]; then
        source "${ACME_DIR}/acme.sh.env"
    fi
    
    register_rollback "Remove acme.sh" "rm -rf '${ACME_DIR}'" "cleanup"
    
    log_success "acme.sh installed"
}

# Stop services and containers using port 80
free_port_80() {
    log_info "Checking for services using port 80..."
    
    local services_stopped=()
    
    # Check for systemd services on port 80
    local service_on_80
    service_on_80=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP '(?<=users:\(\(")[^"]+' | head -1)
    
    if [[ -n "$service_on_80" ]]; then
        log_info "Stopping service ${service_on_80} on port 80..."
        systemctl stop "$service_on_80" 2>/dev/null || true
        services_stopped+=("systemd:$service_on_80")
    fi
    
    # Check for Docker containers on port 80
    local containers_on_80
    containers_on_80=$(docker ps --format '{{.Names}}' --filter "publish=80" 2>/dev/null || true)
    
    for container in $containers_on_80; do
        if [[ -n "$container" ]]; then
            log_info "Stopping Docker container ${container} using port 80..."
            docker stop "$container" 2>/dev/null || true
            services_stopped+=("docker:$container")
        fi
    done
    
    # Also check by port binding directly
    local pid_on_80
    pid_on_80=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP '(?<=pid=)\d+' | head -1)
    
    if [[ -n "$pid_on_80" ]]; then
        local process_name
        process_name=$(ps -p "$pid_on_80" -o comm= 2>/dev/null || echo "unknown")
        log_warn "Process ${process_name} (PID: ${pid_on_80}) is still using port 80"
    fi
    
    # Return list of stopped services for restart
    printf '%s\n' "${services_stopped[@]}"
}

# Restart services that were stopped
restart_services() {
    local services=("$@")
    
    for service in "${services[@]}"; do
        if [[ -z "$service" ]]; then
            continue
        fi
        
        local type="${service%%:*}"
        local name="${service#*:}"
        
        case "$type" in
            systemd)
                log_info "Restarting systemd service ${name}..."
                systemctl start "$name" 2>/dev/null || true
                ;;
            docker)
                log_info "Restarting Docker container ${name}..."
                docker start "$name" 2>/dev/null || true
                ;;
        esac
    done
}

# Issue certificate using standalone mode
issue_certificate_standalone() {
    local domain="$1"
    local email="$2"
    
    log_info "Issuing SSL certificate for ${domain} (standalone mode)..."
    
    # Free port 80
    local stopped_services
    mapfile -t stopped_services < <(free_port_80)
    
    # Register rollback to restart services
    if [[ ${#stopped_services[@]} -gt 0 ]]; then
        register_rollback "Restart services after SSL" \
            "restart_services ${stopped_services[*]}" \
            "normal"
    fi
    
    # Wait for port to be free
    local retries=0
    while ss -tlnp 2>/dev/null | grep -q ':80 ' && [[ $retries -lt 10 ]]; do
        sleep 1
        ((retries++))
    done
    
    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        log_error "Port 80 is still in use after cleanup attempts"
        restart_services "${stopped_services[@]}"
        return 1
    fi
    
    # Issue certificate with timeout
    local result=0
    if ! timeout 300 "${ACME_DIR}/acme.sh" --issue \
        --standalone \
        -d "$domain" \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$email" \
        --force; then
        result=1
    fi
    
    # Restart stopped services
    restart_services "${stopped_services[@]}"
    
    return $result
}

# Issue certificate using webroot mode
issue_certificate_webroot() {
    local domain="$1"
    local email="$2"
    local webroot="${3:-/var/www/html}"
    
    log_info "Issuing SSL certificate for ${domain} (webroot mode)..."
    
    create_dir "$webroot"
    
    timeout 300 "${ACME_DIR}/acme.sh" --issue \
        --webroot "$webroot" \
        -d "$domain" \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$email" \
        --force
}

# Install certificate to target directory
install_certificate() {
    local domain="$1"
    local target_dir="${2:-$SSL_DIR}"
    
    log_info "Installing certificate for ${domain} to ${target_dir}..."
    
    create_dir "$target_dir" "0700"
    
    if ! "${ACME_DIR}/acme.sh" --install-cert -d "$domain" \
        --key-file "${target_dir}/${domain}.key" \
        --fullchain-file "${target_dir}/${domain}.crt" \
        --reloadcmd "docker restart marzban 2>/dev/null || true"; then
        log_error "Failed to install certificate"
        return 1
    fi
    
    # Set proper permissions
    chmod 0600 "${target_dir}/${domain}.key"
    chmod 0644 "${target_dir}/${domain}.crt"
    
    register_file "${target_dir}/${domain}.key"
    register_file "${target_dir}/${domain}.crt"
    
    log_success "Certificate installed to ${target_dir}"
}

# Issue certificate for multiple domains
issue_multi_domain_certificate() {
    local email="$1"
    shift
    local domains=("$@")
    
    log_info "Issuing multi-domain certificate..."
    
    # Build domain arguments
    local domain_args=""
    for domain in "${domains[@]}"; do
        domain_args+=" -d ${domain}"
    done
    
    # Free port 80
    local stopped_services
    mapfile -t stopped_services < <(free_port_80)
    
    # Issue certificate
    local result=0
    if ! timeout 300 "${ACME_DIR}/acme.sh" --issue \
        --standalone \
        $domain_args \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$email" \
        --force; then
        result=1
    fi
    
    # Restart services
    restart_services "${stopped_services[@]}"
    
    return $result
}

# Setup auto-renewal cron
setup_auto_renewal() {
    log_info "Setting up auto-renewal..."
    
    # acme.sh installs its own cron, but let's verify
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        log_success "Auto-renewal cron already configured"
        return 0
    fi
    
    # Install cron entry
    "${ACME_DIR}/acme.sh" --install-cronjob
    
    log_success "Auto-renewal configured"
}

# Check certificate validity
check_certificate_validity() {
    local cert_file="$1"
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate file not found: ${cert_file}"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    
    if [[ -z "$expiry_date" ]]; then
        log_error "Could not read certificate expiry date"
        return 1
    fi
    
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    if [[ $days_left -lt 0 ]]; then
        log_error "Certificate has expired!"
        return 1
    elif [[ $days_left -lt 30 ]]; then
        log_warn "Certificate expires in ${days_left} days"
    else
        log_success "Certificate valid for ${days_left} days (expires: ${expiry_date})"
    fi
    
    return 0
}

# Generate self-signed certificate (fallback)
generate_self_signed() {
    local domain="$1"
    local target_dir="${2:-$SSL_DIR}"
    
    log_warn "Generating self-signed certificate for ${domain}..."
    
    create_dir "$target_dir" "0700"
    
    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${target_dir}/${domain}.key" \
        -out "${target_dir}/${domain}.crt" \
        -subj "/CN=${domain}/O=Marzban/C=US" 2>/dev/null; then
        log_error "Failed to generate self-signed certificate"
        return 1
    fi
    
    chmod 0600 "${target_dir}/${domain}.key"
    chmod 0644 "${target_dir}/${domain}.crt"
    
    register_file "${target_dir}/${domain}.key"
    register_file "${target_dir}/${domain}.crt"
    
    log_warn "Self-signed certificate generated. Consider using Let's Encrypt for production."
}

# Main SSL setup function
setup_ssl() {
    local domain="$1"
    local email="$2"
    local target_dir="${3:-$SSL_DIR}"
    
    log_step "Setting up SSL Certificate"
    
    # Create SSL directory
    create_dir "$target_dir" "0700"
    
    # Install acme.sh if needed
    if ! check_acme_installed; then
        if ! install_acme; then
            log_warn "acme.sh installation failed, will use self-signed certificate"
        fi
    fi
    
    # Get server IP for validation
    local server_ip
    server_ip=$(get_public_ip)
    
    if [[ -z "$server_ip" ]]; then
        log_warn "Could not determine server IP, skipping domain validation"
    else
        # Validate domain resolves correctly
        if ! validate_domain "$domain" "$server_ip"; then
            log_warn "Domain validation failed. Certificate may not be issued."
            log_warn "Make sure DNS is configured correctly: ${domain} -> ${server_ip}"
            
            if ! confirm_action "Continue anyway? (will use self-signed if LE fails)" "n"; then
                return 1
            fi
        fi
    fi
    
    # Try to issue certificate if acme.sh is available
    local cert_issued=false
    
    if [[ -f "${ACME_DIR}/acme.sh" ]]; then
        log_info "Attempting to issue Let's Encrypt certificate..."
        
        if issue_certificate_standalone "$domain" "$email"; then
            if install_certificate "$domain" "$target_dir"; then
                setup_auto_renewal
                cert_issued=true
                log_success "Let's Encrypt certificate issued and installed"
            fi
        fi
    fi
    
    # Fallback to self-signed
    if [[ "$cert_issued" != "true" ]]; then
        log_warn "Let's Encrypt failed or unavailable, generating self-signed certificate..."
        if ! generate_self_signed "$domain" "$target_dir"; then
            log_error "Failed to generate SSL certificate"
            return 1
        fi
    fi
    
    # Verify certificate
    if ! check_certificate_validity "${target_dir}/${domain}.crt"; then
        log_error "Certificate validation failed"
        return 1
    fi
    
    log_success "SSL setup completed"
    
    # Return paths
    echo "CERT_FILE=${target_dir}/${domain}.crt"
    echo "KEY_FILE=${target_dir}/${domain}.key"
}

# Renew all certificates
renew_certificates() {
    log_info "Renewing all certificates..."
    
    if [[ ! -f "${ACME_DIR}/acme.sh" ]]; then
        log_error "acme.sh not installed"
        return 1
    fi
    
    "${ACME_DIR}/acme.sh" --renew-all --force
    
    log_success "Certificate renewal completed"
}

# List all certificates managed by acme.sh
list_certificates() {
    log_info "Listing managed certificates..."
    
    if [[ -f "${ACME_DIR}/acme.sh" ]]; then
        "${ACME_DIR}/acme.sh" --list
    else
        log_warn "acme.sh not installed"
    fi
}
