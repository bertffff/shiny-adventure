#!/bin/bash
# =============================================================================
# MARZBAN VPN SERVER UNINSTALLER
# Clean Removal Script
# =============================================================================

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# Data directory
DATA_DIR="/opt/marzban"

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Get SSH port before any changes
detect_ssh_port() {
    local ssh_port=""
    
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
    fi
    
    echo "${ssh_port:-22}"
}

SSH_PORT=$(detect_ssh_port)

echo ""
echo -e "${RED}${BOLD}========================================${NC}"
echo -e "${RED}${BOLD}    MARZBAN VPN SERVER UNINSTALLER     ${NC}"
echo -e "${RED}${BOLD}========================================${NC}"
echo ""
echo -e "${YELLOW}This will remove:${NC}"
echo "  - Marzban Docker containers"
echo "  - AdGuard Home Docker containers"
echo "  - Marzban data directory (${DATA_DIR})"
echo "  - Docker network (marzban-network)"
echo "  - UFW firewall rules (optional)"
echo "  - acme.sh and SSL certificates (optional)"
echo ""
echo -e "${RED}WARNING: This action is IRREVERSIBLE!${NC}"
echo -e "${CYAN}Your SSH port (${SSH_PORT}) will be preserved.${NC}"
echo ""

read -rp "Are you sure you want to uninstall? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    log_info "Uninstallation cancelled"
    exit 0
fi

echo ""

# Stop and remove Docker containers
log_info "Stopping Docker containers..."

# Stop Marzban
if [[ -d "$DATA_DIR" ]]; then
    cd "$DATA_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
fi

# Stop AdGuard
if [[ -d "${DATA_DIR}/adguard" ]]; then
    cd "${DATA_DIR}/adguard" 2>/dev/null && docker compose down 2>/dev/null || true
fi

# Stop containers by name if still running
for container in marzban adguardhome; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        log_info "Stopping container: ${container}"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
    fi
done

log_success "Docker containers stopped and removed"

# Remove Docker network
log_info "Removing Docker network..."
docker network rm marzban-network 2>/dev/null || true
log_success "Docker network removed"

# Backup data before removal
read -rp "Do you want to backup ${DATA_DIR} before removal? (y/n): " backup_choice
if [[ "$backup_choice" == "y" || "$backup_choice" == "Y" ]]; then
    backup_dir="/root/marzban-backup-$(date +%Y%m%d_%H%M%S)"
    log_info "Creating backup at ${backup_dir}..."
    
    if cp -r "$DATA_DIR" "$backup_dir" 2>/dev/null; then
        # Remove sensitive files from backup or encrypt them
        chmod 0700 "$backup_dir"
        log_success "Backup created: ${backup_dir}"
        echo ""
        echo -e "${YELLOW}Note: Backup contains sensitive data (passwords, keys).${NC}"
        echo -e "${YELLOW}Consider encrypting or securely storing this backup.${NC}"
        echo ""
    else
        log_warn "Backup failed, but continuing with uninstallation"
    fi
fi

# Remove Marzban data
log_info "Removing Marzban data directory..."
if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
    log_success "Removed: ${DATA_DIR}"
fi

if [[ -d "/var/lib/marzban" ]]; then
    rm -rf /var/lib/marzban
    log_success "Removed: /var/lib/marzban"
fi

# Remove WARP tools
log_info "Removing WARP tools..."
rm -f /usr/local/bin/wgcf
log_success "WARP tools removed"

# Remove bcrypt venv
if [[ -d /opt/bcrypt-venv ]]; then
    rm -rf /opt/bcrypt-venv
    log_success "Removed bcrypt virtual environment"
fi

# Remove UFW rules (optional)
read -rp "Do you want to reset UFW firewall rules? (y/n): " ufw_choice
if [[ "$ufw_choice" == "y" || "$ufw_choice" == "Y" ]]; then
    log_info "Resetting UFW rules..."
    log_warn "SSH port ${SSH_PORT} will be preserved"
    
    ufw --force disable 2>/dev/null || true
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    ufw --force enable
    
    log_success "UFW rules reset (SSH port ${SSH_PORT} preserved)"
fi

# Remove acme.sh and certificates (optional)
read -rp "Do you want to remove acme.sh and SSL certificates? (y/n): " acme_choice
if [[ "$acme_choice" == "y" || "$acme_choice" == "Y" ]]; then
    log_info "Removing acme.sh..."
    
    # Uninstall acme.sh properly
    if [[ -f /root/.acme.sh/acme.sh ]]; then
        /root/.acme.sh/acme.sh --uninstall 2>/dev/null || true
    fi
    
    rm -rf /root/.acme.sh
    
    # Remove cron entries
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null || true
    
    log_success "acme.sh removed"
fi

# Restore systemd-resolved if it was disabled
read -rp "Do you want to re-enable systemd-resolved (DNS)? (y/n): " resolved_choice
if [[ "$resolved_choice" == "y" || "$resolved_choice" == "Y" ]]; then
    log_info "Re-enabling systemd-resolved..."
    
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
    
    # Restore symlink
    if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    
    log_success "systemd-resolved re-enabled"
fi

# Remove Docker (optional)
read -rp "Do you want to remove Docker completely? (y/n): " docker_choice
if [[ "$docker_choice" == "y" || "$docker_choice" == "Y" ]]; then
    log_warn "This will remove Docker and ALL Docker data!"
    read -rp "Are you absolutely sure? (yes/no): " docker_confirm
    
    if [[ "$docker_confirm" == "yes" ]]; then
        log_info "Removing Docker..."
        
        # Stop Docker service
        systemctl stop docker 2>/dev/null || true
        systemctl disable docker 2>/dev/null || true
        
        # Remove packages
        apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        
        # Remove Docker data
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
        rm -rf /etc/docker
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
        
        log_success "Docker removed"
    else
        log_info "Docker removal cancelled"
    fi
fi

# Remove installation logs
read -rp "Do you want to remove installation logs? (y/n): " logs_choice
if [[ "$logs_choice" == "y" || "$logs_choice" == "Y" ]]; then
    rm -f /var/log/marzban-installer.log*
    log_success "Installation logs removed"
fi

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}    UNINSTALLATION COMPLETED           ${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
log_success "Marzban VPN Server has been uninstalled"

if [[ -n "${backup_dir:-}" ]] && [[ -d "${backup_dir:-}" ]]; then
    echo ""
    echo -e "${YELLOW}Backup saved at: ${backup_dir}${NC}"
fi

echo ""

exit 0
