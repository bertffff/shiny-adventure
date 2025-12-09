#!/bin/bash
# =============================================================================
# MODULE: firewall.sh - UFW Firewall Configuration
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# UFW FIREWALL CONFIGURATION
# -----------------------------------------------------------------------------

# Track if UFW was enabled by us
UFW_WAS_INACTIVE=false

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
    
    register_rollback "Remove UFW" "apt-get remove -y ufw" "normal"
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
    
    # Critical rollback - restore UFW rules on failure
    register_rollback "Restore UFW rules" \
        "ufw --force reset && cp -r '${backup_dir}'/* /etc/ufw/ 2>/dev/null; ufw --force enable" \
        "critical"
    
    log_success "UFW rules backed up to ${backup_dir}"
    echo "$backup_dir"
}

# Configure UFW default policies
configure_ufw_defaults() {
    log_info "Configuring UFW default policies..."
    
    # Check if UFW is currently active
    if ufw status | grep -q "Status: active"; then
        UFW_WAS_INACTIVE=false
    else
        UFW_WAS_INACTIVE=true
    fi
    
    # Disable UFW first to make changes safely
    ufw --force disable &>/dev/null || true
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    log_success "UFW defaults configured (deny incoming, allow outgoing)"
}

# Allow SSH port (auto-detected) - CRITICAL FUNCTION
allow_ssh() {
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    log_info "Detected SSH port: ${ssh_port}"
    log_warn "CRITICAL: Allowing SSH port ${ssh_port} to prevent lockout"
    
    # Add SSH rule (this works even when UFW is disabled)
    ufw allow "${ssh_port}/tcp" comment "SSH"
    
    # Verify the rule was added by checking the rules file directly
    if [[ -f /etc/ufw/user.rules ]]; then
        if grep -q "dport ${ssh_port}" /etc/ufw/user.rules 2>/dev/null; then
            log_success "SSH port ${ssh_port} rule verified in UFW config"
        fi
    fi
    
    # Register critical rollback to ensure SSH is always accessible
    register_rollback "Emergency SSH access restore" \
        "ufw --force disable; ufw allow ${ssh_port}/tcp; ufw --force enable" \
        "critical"
    
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
        if [[ -n "$port" ]]; then
            log_info "Allowing VPN port: ${port}"
            ufw allow "${port}/tcp" comment "VPN Profile"
        fi
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

# Verify SSH rule exists before enabling UFW
verify_ssh_rule() {
    local ssh_port="$1"
    
    # Check multiple sources for SSH rule
    # 1. Check ufw show added (works before enabling)
    if ufw show added 2>/dev/null | grep -qE "${ssh_port}/tcp.*ALLOW"; then
        return 0
    fi
    
    # 2. Check user.rules file directly
    if [[ -f /etc/ufw/user.rules ]]; then
        if grep -qE "dport ${ssh_port}" /etc/ufw/user.rules 2>/dev/null; then
            return 0
        fi
    fi
    
    # 3. Check user6.rules for IPv6
    if [[ -f /etc/ufw/user6.rules ]]; then
        if grep -qE "dport ${ssh_port}" /etc/ufw/user6.rules 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Enable UFW - SINGLE DEFINITION, with safety checks
enable_ufw() {
    log_info "Enabling UFW..."
    
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    # CRITICAL: Verify SSH rule exists before enabling
    if ! verify_ssh_rule "$ssh_port"; then
        log_error "SSH port ${ssh_port} rule not found in UFW configuration!"
        log_error "Adding SSH rule now to prevent lockout..."
        ufw allow "${ssh_port}/tcp" comment "SSH"
        
        # Verify again
        if ! verify_ssh_rule "$ssh_port"; then
            log_error "Failed to add SSH rule. Aborting UFW enable to prevent lockout."
            log_error "Please manually run: ufw allow ${ssh_port}/tcp"
            return 1
        fi
    fi
    
    log_info "SSH port ${ssh_port} verified in UFW rules"
    
    # Enable UFW
    if ! ufw --force enable; then
        log_error "Failed to enable UFW"
        return 1
    fi
    
    # Double-check UFW is active and SSH is accessible
    if ufw status | grep -q "Status: active"; then
        if ufw status | grep -qE "^${ssh_port}/tcp.*ALLOW"; then
            log_success "UFW enabled successfully with SSH port ${ssh_port} accessible"
        else
            log_warn "UFW enabled but SSH rule may not be visible in status"
        fi
    else
        log_error "UFW failed to activate"
        return 1
    fi
    
    return 0
}

# Print UFW status
print_ufw_status() {
    log_info "Current UFW status:"
    echo ""
    ufw status verbose
    echo ""
}

# Check if port is already allowed
is_port_allowed() {
    local port="$1"
    local proto="${2:-tcp}"
    
    if ufw status | grep -qE "^${port}/${proto}\s+ALLOW"; then
        return 0
    fi
    return 1
}

# Main firewall configuration function
configure_firewall() {
    local marzban_port="${1:-8443}"
    local adguard_web_port="${2:-3000}"
    local adguard_dns_port="${3:-53}"
    shift 3
    local vpn_ports=("$@")
    
    log_step "Configuring Firewall (UFW)"
    
    # Install UFW if needed
    if ! check_ufw_installed; then
        install_ufw
    fi
    
    # Backup existing rules
    local backup_dir
    backup_dir=$(backup_ufw_rules)
    
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
    
    # Enable UFW with safety checks
    if ! enable_ufw; then
        log_error "Failed to enable UFW safely"
        log_warn "Restoring previous UFW configuration..."
        ufw --force reset
        if [[ -d "$backup_dir" ]]; then
            cp -r "${backup_dir}"/* /etc/ufw/ 2>/dev/null || true
        fi
        ufw --force enable 2>/dev/null || true
        return 1
    fi
    
    # Print status
    print_ufw_status
    
    log_success "Firewall configuration completed"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}IMPORTANT: Your SSH port is ${ssh_port}${NC}"
    echo -e "${RED}${BOLD}Make sure you can still connect before closing this session!${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Return SSH port for reference
    echo "$ssh_port"
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

# Remove specific port rule
remove_port_rule() {
    local port="$1"
    local proto="${2:-tcp}"
    
    log_info "Removing UFW rule for port ${port}/${proto}"
    
    ufw delete allow "${port}/${proto}" 2>/dev/null || true
    
    log_success "Rule removed"
}

# Reset UFW to defaults (dangerous - use with caution)
reset_ufw() {
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    log_warn "Resetting UFW to defaults..."
    log_warn "SSH port ${ssh_port} will be preserved"
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp" comment "SSH"
    ufw --force enable
    
    log_success "UFW reset completed"
}
