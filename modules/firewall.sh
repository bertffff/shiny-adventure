#!/bin/bash
# =============================================================================
# MODULE: firewall.sh - UFW Firewall Configuration
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# UFW FIREWALL CONFIGURATION
# -----------------------------------------------------------------------------

# Check if UFW is installed
check_ufw_installed() {
    if command_exists ufw; then
        log_info "UFW is already installed"
        return 0
    fi
    return 1
}

# Install UFW
install_ufw() {
    log_info "Installing UFW..."
    
    apt-get update -qq
    apt-get install -y -qq ufw
    
    register_rollback "Remove UFW" "apt-get remove -y ufw"
}

# Backup current UFW rules
backup_ufw_rules() {
    log_info "Backing up current UFW rules..."
    
    local backup_dir="/root/ufw-backup-$(date +%Y%m%d_%H%M%S)"
    create_dir "$backup_dir"
    
    if [[ -d /etc/ufw ]]; then
        cp -r /etc/ufw/* "$backup_dir/" 2>/dev/null || true
    fi
    
    # Save current rules
    ufw status verbose > "${backup_dir}/ufw-status.txt" 2>/dev/null || true
    
    register_rollback "Restore UFW rules" \
        "ufw --force reset && cp -r '${backup_dir}'/* /etc/ufw/ 2>/dev/null && ufw --force enable"
    
    log_success "UFW rules backed up to ${backup_dir}"
}

# Configure UFW default policies
configure_ufw_defaults() {
    log_info "Configuring UFW default policies..."
    
    # Disable UFW first to make changes safely
    ufw --force disable &>/dev/null || true
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    log_success "UFW defaults configured (deny incoming, allow outgoing)"
}

# Allow SSH port (auto-detected)
allow_ssh() {
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    log_info "Detected SSH port: ${ssh_port}"
    log_warn "CRITICAL: Allowing SSH port ${ssh_port} to prevent lockout"
    
    ufw allow "${ssh_port}/tcp" comment "SSH"
    
    log_success "SSH port ${ssh_port} allowed"
    
    echo "$ssh_port"
}

# Allow Marzban panel port
allow_marzban_port() {
    local port="$1"
    
    log_info "Allowing Marzban panel port: ${port}"
    ufw allow "${port}/tcp" comment "Marzban Panel"
    
    log_success "Marzban port ${port} allowed"
}

# Allow AdGuard Home ports
allow_adguard_ports() {
    local web_port="$1"
    local dns_port="${2:-}"
    
    log_info "Allowing AdGuard Home web port: ${web_port}"
    ufw allow "${web_port}/tcp" comment "AdGuard Home Web UI"
    
    # DNS port is usually internal only, but allow if specified
    if [[ -n "$dns_port" && "$dns_port" != "53" ]]; then
        log_info "Allowing AdGuard DNS port: ${dns_port}"
        ufw allow "${dns_port}/tcp" comment "AdGuard DNS TCP"
        ufw allow "${dns_port}/udp" comment "AdGuard DNS UDP"
    fi
    
    log_success "AdGuard ports allowed"
}

# Allow VPN profile ports
allow_vpn_ports() {
    local ports=("$@")
    
    for port in "${ports[@]}"; do
        log_info "Allowing VPN port: ${port}"
        ufw allow "${port}/tcp" comment "VPN Profile"
    done
    
    log_success "VPN ports allowed"
}

# Allow HTTP/HTTPS for SSL certificate renewal
allow_http_https() {
    log_info "Allowing HTTP (80) and HTTPS (443) for SSL"
    
    ufw allow 80/tcp comment "HTTP - SSL Cert"
    ufw allow 443/tcp comment "HTTPS - SSL/VPN"
    
    log_success "HTTP/HTTPS ports allowed"
}

# Enable UFW
enable_ufw() {
    log_info "Enabling UFW..."
    
    # Double-check SSH is allowed before enabling
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
enable_ufw() {
    log_info "Enabling UFW..."
    
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    # Проверяем UFW rules в файле, а не через status (который работает только когда UFW enabled)
    if ! grep -qE "^ufw allow ${ssh_port}/tcp" /etc/ufw/user.rules 2>/dev/null && \
       ! ufw show added | grep -qE "${ssh_port}/tcp.*ALLOW"; then
        log_error "SSH port ${ssh_port} not in UFW rules! Aborting to prevent lockout."
        log_error "Run: ufw allow ${ssh_port}/tcp"
        return 1
    fi
    
    ufw --force enable
    log_success "UFW enabled"
}
    
    # Enable UFW
    ufw --force enable
    
    log_success "UFW enabled"
}

# Print UFW status
print_ufw_status() {
    log_info "Current UFW status:"
    echo ""
    ufw status verbose
    echo ""
}

# Main firewall configuration function
configure_firewall() {
    local marzban_port="${1:-8443}"
    local adguard_web_port="${2:-3000}"
    local adguard_dns_port="${3:-53}"
    local vpn_ports=("${@:4}")
    
    log_step "Configuring Firewall (UFW)"
    
    # Install UFW if needed
    if ! check_ufw_installed; then
        install_ufw
    fi
    
    # Backup existing rules
    backup_ufw_rules
    
    # Configure defaults
    configure_ufw_defaults
    
    # Allow SSH FIRST (critical!)
    local ssh_port
    ssh_port=$(allow_ssh)
    
    # Allow HTTP/HTTPS
    allow_http_https
    
    # Allow Marzban
    allow_marzban_port "$marzban_port"
    
    # Allow AdGuard
    allow_adguard_ports "$adguard_web_port" "$adguard_dns_port"
    
    # Allow VPN ports
    if [[ ${#vpn_ports[@]} -gt 0 ]]; then
        allow_vpn_ports "${vpn_ports[@]}"
    fi
    
    # Enable UFW
    enable_ufw
    
    # Print status
    print_ufw_status
    
    log_success "Firewall configuration completed"
    echo ""
    log_warn "IMPORTANT: Your SSH port is ${ssh_port}"
    log_warn "Make sure you can still connect before closing this session!"
    echo ""
}

# Quick check if firewall allows a port
check_port_allowed() {
    local port="$1"
    
    if ufw status | grep -qE "^${port}(/tcp)?\s+ALLOW"; then
        return 0
    fi
    return 1
}

# Add emergency SSH access (use if locked out from console)
emergency_ssh_access() {
    local port="${1:-22}"
    
    log_warn "Adding emergency SSH access on port ${port}"
    
    ufw --force disable
    ufw allow "${port}/tcp" comment "Emergency SSH"
    ufw --force enable
    
    log_success "Emergency SSH access added on port ${port}"
}
