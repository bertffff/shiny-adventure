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
    
    # Install acme.sh
    curl -fsSL https://get.acme.sh | sh -s email="${SSL_EMAIL:-admin@example.com}"
    
    # Reload shell
    source "${ACME_DIR}/acme.sh.env" 2>/dev/null || true
    
    register_rollback "Remove acme.sh" "rm -rf '${ACME_DIR}'"
    
    log_success "acme.sh installed"
}

# Issue certificate using standalone mode
issue_certificate_standalone() {
    local domain="$1"
    local email="$2"
    
    log_info "Issuing SSL certificate for ${domain} (standalone mode)..."

    # Check if port 80 is in use
    local service_on_80=""
    if ss -tlnp | grep -q ':80 '; then
        # Extract service name more reliably
        local port_info
        port_info=$(ss -tlnp | grep ':80 ' | head -1)
        # Try to extract process name from the output
        if echo "$port_info" | grep -q 'users:'; then
            service_on_80=$(echo "$port_info" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)
        fi

        if [[ -n "$service_on_80" ]]; then
            log_warn "Port 80 is in use by ${service_on_80}. Attempting to stop temporarily..."
            systemctl stop "$service_on_80" 2>/dev/null || true
            register_rollback "Restart ${service_on_80}" "systemctl start '${service_on_80}' 2>/dev/null || true"
            sleep 2
        else
            log_warn "Port 80 is in use, but could not determine service name. Certificate issuance may fail."
        fi
    fi

    # Issue certificate (without --force to respect rate limits)
    "${ACME_DIR}/acme.sh" --issue \
        --standalone \
        -d "$domain" \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$email"
    
    local result=$?
    
    # Restart service if we stopped it
    if [[ -n "$service_on_80" ]]; then
        systemctl start "$service_on_80" 2>/dev/null || true
    fi
    
    return $result
}

# Issue certificate using webroot mode
issue_certificate_webroot() {
    local domain="$1"
    local email="$2"
    local webroot="${3:-/var/www/html}"
    
    log_info "Issuing SSL certificate for ${domain} (webroot mode)..."
    
    create_dir "$webroot"
    
    "${ACME_DIR}/acme.sh" --issue \
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
    
    "${ACME_DIR}/acme.sh" --install-cert -d "$domain" \
        --key-file "${target_dir}/${domain}.key" \
        --fullchain-file "${target_dir}/${domain}.crt" \
        --reloadcmd "docker restart marzban 2>/dev/null || true"
    
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
    
    # Issue certificate
    "${ACME_DIR}/acme.sh" --issue \
        --standalone \
        $domain_args \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$email" \
        --force
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
    expiry_epoch=$(date -d "$expiry_date" +%s)
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
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${target_dir}/${domain}.key" \
        -out "${target_dir}/${domain}.crt" \
        -subj "/CN=${domain}/O=Marzban/C=US"
    
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
        install_acme
    fi
    
    # Validate domain resolves correctly
    local server_ip
    server_ip=$(get_public_ip)
    
    if ! validate_domain "$domain" "$server_ip"; then
        log_warn "Domain validation failed. Certificate may not be issued."
        log_warn "Make sure DNS is configured correctly: ${domain} -> ${server_ip}"
        
        if confirm_action "Continue anyway? (will use self-signed if LE fails)" "n"; then
            :
        else
            return 1
        fi
    fi
    
    # Try to issue certificate
    log_info "Attempting to issue Let's Encrypt certificate..."
    
    if issue_certificate_standalone "$domain" "$email"; then
        install_certificate "$domain" "$target_dir"
        setup_auto_renewal
        log_success "Let's Encrypt certificate issued and installed"
    else
        log_warn "Let's Encrypt failed, generating self-signed certificate..."
        generate_self_signed "$domain" "$target_dir"
    fi
    
    # Verify certificate
    check_certificate_validity "${target_dir}/${domain}.crt"
    
    log_success "SSL setup completed"
    
    # Return paths
    echo "CERT_FILE=${target_dir}/${domain}.crt"
    echo "KEY_FILE=${target_dir}/${domain}.key"
}

# Renew all certificates
renew_certificates() {
    log_info "Renewing all certificates..."
    
    "${ACME_DIR}/acme.sh" --renew-all --force
    
    log_success "Certificate renewal completed"
}
