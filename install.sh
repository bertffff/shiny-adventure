#!/bin/bash
# =============================================================================
# MARZBAN VPN SERVER INSTALLER
# Main Installation Script
# =============================================================================
# 
# This script installs and configures:
# - Docker & Docker Compose
# - Marzban Panel with Xray core
# - AdGuard Home DNS server
# - Cloudflare WARP outbound
# - UFW Firewall
# - SSL Certificates (Let's Encrypt)
# - Three VPN profiles:
#   1. Whitelist Bypass (port 443, SNI: vk.com)
#   2. Standard Fast (direct routing)
#   3. Via WARP (geo-unblock)
#
# Usage: sudo ./install.sh
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load modules
source "${SCRIPT_DIR}/modules/core.sh"
source "${SCRIPT_DIR}/modules/docker.sh"
source "${SCRIPT_DIR}/modules/firewall.sh"
source "${SCRIPT_DIR}/modules/ssl.sh"
source "${SCRIPT_DIR}/modules/reality.sh"
source "${SCRIPT_DIR}/modules/warp.sh"
source "${SCRIPT_DIR}/modules/adguard.sh"
source "${SCRIPT_DIR}/modules/marzban.sh"
source "${SCRIPT_DIR}/modules/marzban_api.sh"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

CONFIG_FILE="${SCRIPT_DIR}/config.env"
INSTALLATION_LOG="/var/log/marzban-installer.log"
MAX_LOG_SIZE=10485760  # 10MB

# Default values (overridden by config.env)
PANEL_DOMAIN=""
SUB_DOMAIN=""
SSL_EMAIL=""
MARZBAN_ADMIN_USER="admin"
MARZBAN_ADMIN_PASS=""
MARZBAN_PORT="8443"
ADGUARD_WEB_PORT="3000"
ADGUARD_DNS_PORT="53"
ADGUARD_USER="admin"
ADGUARD_PASS=""
PROFILE1_PORT="443"
PROFILE1_SNI="www.vk.com"
PROFILE1_NAME="Whitelist-VK"
PROFILE2_PORT="8444"
PROFILE2_SNI="www.microsoft.com"
PROFILE2_NAME="Standard-Fast"
PROFILE3_PORT="2053"
PROFILE3_SNI="dl.google.com"
PROFILE3_NAME="Via-WARP"
DOCKER_NETWORK="marzban-network"
DATA_DIR="/opt/marzban"
TZ="Europe/Amsterdam"
DEBUG_MODE="false"

# Track installation state for idempotency
DOCKER_INSTALLED=false
NETWORK_CREATED=false
FIREWALL_CONFIGURED=false
SSL_CONFIGURED=false
REALITY_KEYS_GENERATED=false
WARP_CONFIGURED=false
ADGUARD_INSTALLED=false
MARZBAN_INSTALLED=false

# -----------------------------------------------------------------------------
# REQUIRED DEPENDENCIES
# -----------------------------------------------------------------------------

REQUIRED_COMMANDS=(
    "curl"
    "wget"
    "openssl"
    "jq"
)

OPTIONAL_COMMANDS=(
    "dig"
    "nc"
    "ss"
)

# -----------------------------------------------------------------------------
# LOAD CONFIGURATION
# -----------------------------------------------------------------------------

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log_error "Configuration file not found: ${CONFIG_FILE}"
        log_info "Please copy config.env.example to config.env and fill in your values:"
        echo "  cp ${SCRIPT_DIR}/config.env.example ${SCRIPT_DIR}/config.env"
        echo "  nano ${SCRIPT_DIR}/config.env"
        exit 1
    fi
    
    # Validate required fields
    local missing_fields=()
    
    [[ -z "$PANEL_DOMAIN" ]] && missing_fields+=("PANEL_DOMAIN")
    [[ -z "$SUB_DOMAIN" ]] && missing_fields+=("SUB_DOMAIN")
    [[ -z "$SSL_EMAIL" ]] && missing_fields+=("SSL_EMAIL")
    
    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        log_error "Missing required configuration fields:"
        for field in "${missing_fields[@]}"; do
            echo "  - ${field}"
        done
        exit 1
    fi
    
    # Use panel domain as sub domain if not specified or same
    [[ "$SUB_DOMAIN" == "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]] && SUB_DOMAIN="$PANEL_DOMAIN"
    
    # Export DATA_DIR for other modules
    export DATA_DIR
    export TZ
    export DEBUG_MODE
    
    log_success "Configuration loaded"
}

# -----------------------------------------------------------------------------
# DEPENDENCY CHECKS
# -----------------------------------------------------------------------------

check_dependencies() {
    log_step "Checking Dependencies"
    
    local missing_required=()
    local missing_optional=()
    
    # Check required commands
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command_exists "$cmd"; then
            missing_required+=("$cmd")
        fi
    done
    
    # Check optional commands
    for cmd in "${OPTIONAL_COMMANDS[@]}"; do
        if ! command_exists "$cmd"; then
            missing_optional+=("$cmd")
        fi
    done
    
    # Install missing required dependencies
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        log_info "Installing missing required dependencies: ${missing_required[*]}"
        apt-get update -qq
        
        for cmd in "${missing_required[@]}"; do
            case "$cmd" in
                jq)
                    apt-get install -y -qq jq
                    ;;
                curl)
                    apt-get install -y -qq curl
                    ;;
                wget)
                    apt-get install -y -qq wget
                    ;;
                openssl)
                    apt-get install -y -qq openssl
                    ;;
            esac
        done
    fi
    
    # Install missing optional dependencies
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_info "Installing optional dependencies: ${missing_optional[*]}"
        
        for cmd in "${missing_optional[@]}"; do
            case "$cmd" in
                dig)
                    apt-get install -y -qq dnsutils 2>/dev/null || true
                    ;;
                nc)
                    apt-get install -y -qq netcat-openbsd 2>/dev/null || true
                    ;;
                ss)
                    apt-get install -y -qq iproute2 2>/dev/null || true
                    ;;
            esac
        done
    fi
    
    # Verify required commands are now available
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command_exists "$cmd"; then
            log_error "Required command not available after installation: ${cmd}"
            exit 1
        fi
    done
    
    log_success "All required dependencies are available"
}

# -----------------------------------------------------------------------------
# PRE-INSTALLATION CHECKS
# -----------------------------------------------------------------------------

pre_installation_checks() {
    log_step "Running Pre-Installation Checks"
    
    # Check root
    check_root
    
    # Check system requirements
    check_system_requirements
    
    # Check for existing installation
    if check_existing_installation "$DATA_DIR"; then
        log_warn "Existing installation detected!"
        if ! confirm_action "Continue with installation? (may overwrite existing config)" "n"; then
            log_info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    # Get server IP
    log_info "Detecting server IP address..."
    SERVER_IP=$(get_public_ip)
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Could not determine server IP address"
        exit 1
    fi
    log_success "Server IP: ${SERVER_IP}"
    
    # Detect SSH port
    SSH_PORT=$(detect_ssh_port)
    log_info "Detected SSH port: ${SSH_PORT}"
    
    # Check if ports are available
    log_info "Checking port availability..."
    local ports_to_check=(
        "$MARZBAN_PORT"
        "$PROFILE1_PORT"
        "$PROFILE2_PORT"
        "$PROFILE3_PORT"
    )
    
    local ports_in_use=()
    for port in "${ports_to_check[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            ports_in_use+=("$port")
        fi
    done
    
    if [[ ${#ports_in_use[@]} -gt 0 ]]; then
        log_warn "The following ports are already in use: ${ports_in_use[*]}"
        if ! confirm_action "Continue anyway?" "n"; then
            exit 1
        fi
    fi
    
    # Check disk space (need at least 5GB for Docker images)
    local free_space
    free_space=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ -n "$free_space" && "$free_space" -lt 5 ]]; then
        log_error "Insufficient disk space: ${free_space}GB free (need at least 5GB)"
        exit 1
    fi
    
    log_success "Pre-installation checks completed"
}

# -----------------------------------------------------------------------------
# SETUP LOG ROTATION
# -----------------------------------------------------------------------------

setup_logging() {
    # Rotate log if too large
    rotate_log "$INSTALLATION_LOG" "$MAX_LOG_SIZE"
    
    # Create log directory if needed
    mkdir -p "$(dirname "$INSTALLATION_LOG")"
    
    # Start logging
    exec > >(tee -a "$INSTALLATION_LOG") 2>&1
    
    log_info "Installation started at $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "Log file: ${INSTALLATION_LOG}"
}

# -----------------------------------------------------------------------------
# MAIN INSTALLATION
# -----------------------------------------------------------------------------

main_installation() {
    # Setup logging first
    setup_logging
    
    # Setup error handling
    setup_error_trap
    
    print_banner
    
    echo -e "${BOLD}Starting Marzban VPN Server Installation${NC}"
    echo "Installation log: ${INSTALLATION_LOG}"
    echo ""
    
    # Load configuration
    load_config
    
    # Check dependencies
    check_dependencies
    
    # Pre-installation checks
    pre_installation_checks
    
    # Confirm installation
    echo ""
    print_separator
    echo -e "${CYAN}Installation Summary:${NC}"
    print_separator
    echo "Panel Domain: ${PANEL_DOMAIN}"
    echo "Subscription Domain: ${SUB_DOMAIN}"
    echo "Server IP: ${SERVER_IP}"
    echo "Panel Port: ${MARZBAN_PORT}"
    echo "VPN Ports: ${PROFILE1_PORT}, ${PROFILE2_PORT}, ${PROFILE3_PORT}"
    echo "AdGuard Web Port: ${ADGUARD_WEB_PORT}"
    echo "SSH Port: ${SSH_PORT}"
    print_separator
    echo ""
    
    if ! confirm_action "Proceed with installation?" "y"; then
        log_info "Installation cancelled by user"
        exit 0
    fi
    
    # =========================================================================
    # Step 1: Install Docker
    # =========================================================================
    if ! check_docker_installed || ! check_docker_compose_installed; then
        install_docker
    else
        log_info "Docker already installed, skipping..."
    fi
    DOCKER_INSTALLED=true
    
    # =========================================================================
    # Step 2: Create Docker network
    # =========================================================================
    if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
        create_docker_network "$DOCKER_NETWORK"
    else
        log_info "Docker network ${DOCKER_NETWORK} already exists, skipping..."
    fi
    NETWORK_CREATED=true
    
    # =========================================================================
    # Step 3: Configure Firewall
    # =========================================================================
    configure_firewall "$MARZBAN_PORT" "$ADGUARD_WEB_PORT" "$ADGUARD_DNS_PORT" \
        "$PROFILE1_PORT" "$PROFILE2_PORT" "$PROFILE3_PORT"
    FIREWALL_CONFIGURED=true
    
    # =========================================================================
    # Step 4: Setup SSL Certificates
    # =========================================================================
    SSL_OUTPUT=$(setup_ssl "$PANEL_DOMAIN" "$SSL_EMAIL" "${DATA_DIR}/ssl")
    eval "$(echo "$SSL_OUTPUT" | grep -E "^(CERT_FILE|KEY_FILE)=")"
    SSL_CONFIGURED=true
    
    # =========================================================================
    # Step 5: Generate Reality Keys
    # =========================================================================
    REALITY_OUTPUT=$(setup_reality_keys)
    eval "$(echo "$REALITY_OUTPUT" | grep -E '^REALITY_')"
    REALITY_KEYS_GENERATED=true
    
    # =========================================================================
    # Step 6: Setup WARP
    # =========================================================================
    if ! setup_warp; then
        log_warn "WARP setup failed, Profile 3 will use direct routing"
    else
        WARP_CONFIGURED=true
    fi
    
    # =========================================================================
    # Step 7: Setup AdGuard Home
    # =========================================================================
    ADGUARD_OUTPUT=$(setup_adguard "$ADGUARD_USER" "$ADGUARD_PASS" "$ADGUARD_WEB_PORT" "$ADGUARD_DNS_PORT")
    eval "$(echo "$ADGUARD_OUTPUT" | grep -E '^ADGUARD_')"
    ADGUARD_INSTALLED=true
    
    # =========================================================================
    # Step 8: Install Marzban
    # =========================================================================
    install_marzban \
        "$MARZBAN_ADMIN_USER" \
        "$MARZBAN_ADMIN_PASS" \
        "$PANEL_DOMAIN" \
        "$SUB_DOMAIN" \
        "$MARZBAN_PORT" \
        "${ADGUARD_DNS:-adguardhome:53}" \
        "${DATA_DIR}/ssl/${PANEL_DOMAIN}.crt" \
        "${DATA_DIR}/ssl/${PANEL_DOMAIN}.key" \
        "$PROFILE1_PORT" "$PROFILE2_PORT" "$PROFILE3_PORT"
    MARZBAN_INSTALLED=true
    
    # =========================================================================
    # Step 9: Wait for Marzban
    # =========================================================================
    log_info "Waiting for Marzban to fully initialize..."
    sleep 15
    
    if ! wait_for_marzban "$MARZBAN_PORT" 180; then
        log_error "Marzban failed to start properly"
        show_marzban_logs 100
        
        if confirm_action "Continue despite startup issues?" "n"; then
            log_warn "Continuing with potential issues..."
        else
            execute_rollback
            exit 1
        fi
    fi
    
    if ! check_marzban_health "$MARZBAN_PORT"; then
        log_warn "Marzban health check failed, but continuing..."
    fi
    
    # =========================================================================
    # Step 10: Configure VPN Profiles via API
    # =========================================================================
    local warp_outbound_file=""
    if [[ "$WARP_CONFIGURED" == "true" ]] && [[ -f "${DATA_DIR}/warp/warp_outbound.json" ]]; then
        warp_outbound_file="${DATA_DIR}/warp/warp_outbound.json"
    fi
    
    configure_profiles_via_api \
        "$SERVER_IP" \
        "https://127.0.0.1:${MARZBAN_PORT}" \
        "${MARZBAN_ADMIN_USER}" \
        "${MARZBAN_ADMIN_PASS}" \
        "${REALITY_PRIVATE_KEY}" \
        "${REALITY_PUBLIC_KEY}" \
        "${REALITY_SHORT_IDS}" \
        "$PROFILE1_PORT" "$PROFILE1_SNI" "$PROFILE1_NAME" \
        "$PROFILE2_PORT" "$PROFILE2_SNI" "$PROFILE2_NAME" \
        "$PROFILE3_PORT" "$PROFILE3_SNI" "$PROFILE3_NAME" \
        "$warp_outbound_file"
    
    # Disable error trap for final steps
    disable_error_trap
    
    # Print final summary
    print_final_summary
    
    log_info "Installation completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

# -----------------------------------------------------------------------------
# FINAL SUMMARY
# -----------------------------------------------------------------------------

print_final_summary() {
    local first_short_id
    first_short_id=$(echo "${REALITY_SHORT_IDS:-}" | cut -d',' -f1)
    
    echo ""
    echo ""
    print_separator
    echo -e "${GREEN}${BOLD}       INSTALLATION COMPLETED SUCCESSFULLY!${NC}"
    print_separator
    echo ""
    
    echo -e "${CYAN}=== Marzban Panel ===${NC}"
    echo "URL: https://${PANEL_DOMAIN}:${MARZBAN_PORT}/dashboard"
    echo "Username: ${MARZBAN_ADMIN_USER}"
    echo "Password: ${MARZBAN_ADMIN_PASS}"
    echo ""
    
    echo -e "${CYAN}=== AdGuard Home ===${NC}"
    echo "URL: http://${SERVER_IP}:${ADGUARD_WEB_PORT}"
    echo "Username: ${ADGUARD_USER}"
    echo "Password: ${ADGUARD_PASS}"
    echo ""
    
    echo -e "${CYAN}=== VPN Profiles ===${NC}"
    echo ""
    echo "Profile 1: ${PROFILE1_NAME} (Whitelist Bypass)"
    echo "  Server: ${SERVER_IP}"
    echo "  Port: ${PROFILE1_PORT}"
    echo "  SNI: ${PROFILE1_SNI}"
    echo "  Protocol: VLESS + Reality + Vision"
    echo ""
    echo "Profile 2: ${PROFILE2_NAME} (Standard Fast)"
    echo "  Server: ${SERVER_IP}"
    echo "  Port: ${PROFILE2_PORT}"
    echo "  SNI: ${PROFILE2_SNI}"
    echo "  Protocol: VLESS + Reality + Vision"
    echo ""
    echo "Profile 3: ${PROFILE3_NAME} (Via WARP)"
    echo "  Server: ${SERVER_IP}"
    echo "  Port: ${PROFILE3_PORT}"
    echo "  SNI: ${PROFILE3_SNI}"
    echo "  Protocol: VLESS + Reality + Vision"
    if [[ "$WARP_CONFIGURED" == "true" ]]; then
        echo "  Routing: Via Cloudflare WARP"
    else
        echo "  Routing: Direct (WARP not configured)"
    fi
    echo ""
    
    echo -e "${CYAN}=== Reality Keys ===${NC}"
    echo "Public Key: ${REALITY_PUBLIC_KEY:-N/A}"
    echo "Short ID: ${first_short_id:-N/A}"
    echo ""
    
    echo -e "${CYAN}=== Important Files ===${NC}"
    echo "Marzban Directory: ${DATA_DIR}"
    echo "Admin Credentials: ${DATA_DIR}/admin_credentials.txt"
    echo "Reality Keys: ${DATA_DIR}/keys/reality_keys.env"
    echo "WARP Config: ${DATA_DIR}/warp/warp.conf"
    echo "Installation Log: ${INSTALLATION_LOG}"
    echo ""
    
    echo -e "${CYAN}=== Firewall ===${NC}"
    echo "SSH Port: ${SSH_PORT}"
    echo "Open Ports: ${MARZBAN_PORT}, ${ADGUARD_WEB_PORT}, ${PROFILE1_PORT}, ${PROFILE2_PORT}, ${PROFILE3_PORT}, 80, 443"
    echo ""
    
    print_separator
    echo -e "${YELLOW}IMPORTANT NOTES:${NC}"
    echo "1. Save your Reality Public Key - clients need it to connect"
    echo "2. Make sure DNS is configured: ${PANEL_DOMAIN} -> ${SERVER_IP}"
    echo "3. AdGuard Home UI is accessible for DNS management"
    echo "4. Profile 3 routes all traffic through Cloudflare WARP"
    echo "5. Check the installation log for any warnings"
    print_separator
    echo ""
    
    # Save summary to file
    local summary_file="${DATA_DIR}/installation_summary.txt"
    {
        echo "Marzban VPN Server - Installation Summary"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
        echo ""
        echo "Server IP: ${SERVER_IP}"
        echo "Panel URL: https://${PANEL_DOMAIN}:${MARZBAN_PORT}/dashboard"
        echo "Panel Username: ${MARZBAN_ADMIN_USER}"
        echo "Panel Password: ${MARZBAN_ADMIN_PASS}"
        echo ""
        echo "AdGuard URL: http://${SERVER_IP}:${ADGUARD_WEB_PORT}"
        echo "AdGuard Username: ${ADGUARD_USER}"
        echo "AdGuard Password: ${ADGUARD_PASS}"
        echo ""
        echo "Reality Public Key: ${REALITY_PUBLIC_KEY:-N/A}"
        echo "Reality Short ID: ${first_short_id:-N/A}"
        echo ""
        echo "VPN Ports: ${PROFILE1_PORT}, ${PROFILE2_PORT}, ${PROFILE3_PORT}"
        echo ""
        echo "WARP Status: $( [[ "$WARP_CONFIGURED" == "true" ]] && echo "Configured" || echo "Not configured" )"
    } > "$summary_file"
    chmod 0600 "$summary_file"
    
    log_success "Installation summary saved to ${summary_file}"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Marzban VPN Server Installer"
    echo ""
    echo "Usage: sudo ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --debug        Enable debug mode"
    echo ""
    echo "Before running, create config.env from the template:"
    echo "  cp config.env.example config.env"
    echo "  nano config.env"
    echo ""
    echo "For more information, see README.md"
    exit 0
fi

# Enable debug mode if requested
if [[ "${1:-}" == "--debug" ]]; then
    DEBUG_MODE="true"
    export DEBUG_MODE
    log_info "Debug mode enabled"
fi

# Run main installation
main_installation

exit 0
