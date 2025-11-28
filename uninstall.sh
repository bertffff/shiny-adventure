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

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

echo ""
echo -e "${RED}${BOLD}========================================${NC}"
echo -e "${RED}${BOLD}    MARZBAN VPN SERVER UNINSTALLER     ${NC}"
echo -e "${RED}${BOLD}========================================${NC}"
echo ""
echo -e "${YELLOW}This will remove:${NC}"
echo "  - Marzban Docker containers"
echo "  - AdGuard Home Docker containers"
echo "  - Marzban data directory (/opt/marzban)"
echo "  - Docker network (marzban-network)"
echo "  - UFW firewall rules (optional)"
echo "  - acme.sh and SSL certificates (optional)"
echo ""
echo -e "${RED}WARNING: This action is IRREVERSIBLE!${NC}"
echo ""

read -rp "Are you sure you want to uninstall? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    log_info "Uninstallation cancelled"
    exit 0
fi

echo ""

# Stop and remove Docker containers
log_info "Stopping Docker containers..."

cd /opt/marzban 2>/dev/null && docker compose down 2>/dev/null || true
cd /opt/marzban/adguard 2>/dev/null && docker compose down 2>/dev/null || true

docker stop marzban 2>/dev/null || true
docker stop adguardhome 2>/dev/null || true

docker rm marzban 2>/dev/null || true
docker rm adguardhome 2>/dev/null || true

log_success "Docker containers stopped and removed"

# Remove Docker network
log_info "Removing Docker network..."
docker network rm marzban-network 2>/dev/null || true
log_success "Docker network removed"

# Backup data before removal
read -rp "Do you want to backup /opt/marzban before removal? (y/n): " backup_choice
if [[ "$backup_choice" == "y" || "$backup_choice" == "Y" ]]; then
    backup_dir="/root/marzban-backup-$(date +%Y%m%d_%H%M%S)"
    log_info "Creating backup at ${backup_dir}..."
    cp -r /opt/marzban "$backup_dir" 2>/dev/null || true
    log_success "Backup created: ${backup_dir}"
fi

# Remove Marzban data
log_info "Removing Marzban data directory..."
rm -rf /opt/marzban
rm -rf /var/lib/marzban
log_success "Marzban data removed"

# Remove WARP tools
log_info "Removing WARP tools..."
rm -f /usr/local/bin/wgcf
log_success "WARP tools removed"

# Remove UFW rules (optional)
read -rp "Do you want to remove UFW firewall rules? (y/n): " ufw_choice
if [[ "$ufw_choice" == "y" || "$ufw_choice" == "Y" ]]; then
    log_info "Resetting UFW rules..."
    
    # Get SSH port before reset
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$ssh_port/tcp" comment "SSH"
    ufw --force enable
    
    log_success "UFW rules reset (SSH port ${ssh_port} preserved)"
fi

# Remove acme.sh and certificates (optional)
read -rp "Do you want to remove acme.sh and SSL certificates? (y/n): " acme_choice
if [[ "$acme_choice" == "y" || "$acme_choice" == "Y" ]]; then
    log_info "Removing acme.sh..."
    rm -rf /root/.acme.sh
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null || true
    log_success "acme.sh removed"
fi

# Remove Docker (optional)
read -rp "Do you want to remove Docker completely? (y/n): " docker_choice
if [[ "$docker_choice" == "y" || "$docker_choice" == "Y" ]]; then
    log_info "Removing Docker..."
    
    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    
    apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    
    rm -rf /var/lib/docker
    rm -rf /etc/docker
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    
    log_success "Docker removed"
fi

# Remove installation logs
rm -f /var/log/marzban-installer.log

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}    UNINSTALLATION COMPLETED           ${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
log_success "Marzban VPN Server has been uninstalled"
echo ""

exit 0
