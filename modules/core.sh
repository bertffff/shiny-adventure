#!/bin/bash
# =============================================================================
# MODULE: core.sh - Core Library (Error Handling, Logging, Utilities)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# COLORS AND FORMATTING
# -----------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# -----------------------------------------------------------------------------
# GLOBAL STATE FOR ROLLBACK
# -----------------------------------------------------------------------------
declare -a CRITICAL_ROLLBACK=()  # Выполняются первыми (UFW, SSH)
declare -a NORMAL_ROLLBACK=()    # Обычные действия
declare -a CLEANUP_ROLLBACK=()   # Очистка файлов (последними)
declare -a CREATED_FILES=()
declare -a STARTED_SERVICES=()
declare -a INSTALLED_PACKAGES=()

# -----------------------------------------------------------------------------
# LOGGING FUNCTIONS
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
    fi
}

log_step() {
    echo -e "\n${BOLD}${GREEN}==>${NC}${BOLD} $*${NC}\n"
}

# -----------------------------------------------------------------------------
# ROLLBACK SYSTEM (Try/Catch Pattern)
# -----------------------------------------------------------------------------

# Register a rollback action with priority
# Usage: register_rollback "description" "command" "[critical|normal|cleanup]"
register_rollback() {
    local description="$1"
    local command="$2"
    local priority="${3:-normal}"  # default to normal
    
    local entry="${description}|||${command}"
    
    case "$priority" in
        critical)
            CRITICAL_ROLLBACK+=("$entry")
            log_debug "Registered CRITICAL rollback: ${description}"
            ;;
        cleanup)
            CLEANUP_ROLLBACK+=("$entry")
            log_debug "Registered CLEANUP rollback: ${description}"
            ;;
        *)
            NORMAL_ROLLBACK+=("$entry")
            log_debug "Registered rollback: ${description}"
            ;;
    esac
}

# Register created file for cleanup
register_file() {
    local filepath="$1"
    CREATED_FILES+=("$filepath")
    log_debug "Registered file: ${filepath}"
}

# Register started service for cleanup
register_service() {
    local service="$1"
    STARTED_SERVICES+=("$service")
    log_debug "Registered service: ${service}"
}

# Execute all rollback actions by priority
execute_rollback() {
    log_error "Installation failed! Executing rollback..."
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}       ROLLBACK IN PROGRESS            ${NC}"
    echo -e "${RED}========================================${NC}"
    
    # Helper function to process a stack
    process_rollback_stack() {
        local stack_name=$1
        shift
        local stack=("$@")
        local i
        
        # Process in reverse order (LIFO) within the priority group
        for (( i=${#stack[@]}-1; i>=0; i-- )); do
            if [[ -n "${stack[$i]:-}" ]]; then
                local description="${stack[$i]%%|||*}"
                local command="${stack[$i]##*|||}"
                log_info "[${stack_name}] Rolling back: ${description}"
                eval "$command" 2>/dev/null || log_warn "Rollback command failed: ${command}"
            fi
        done
    }

    # Stop registered services first
    if [[ ${#STARTED_SERVICES[@]} -gt 0 ]]; then
        for service in "${STARTED_SERVICES[@]}"; do
            if [[ -n "$service" ]]; then
                log_info "Stopping service: ${service}"
                systemctl stop "$service" 2>/dev/null || true
                systemctl disable "$service" 2>/dev/null || true
            fi
        done
    fi
    
    # Stop docker containers
    if command -v docker &>/dev/null; then
        log_info "Stopping Docker containers..."
        cd "${DATA_DIR:-/opt/marzban}" 2>/dev/null && docker compose down 2>/dev/null || true
    fi
    
    # 1. Critical Rollbacks (e.g. Restore Firewall/SSH access)
    if [[ ${#CRITICAL_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Executing CRITICAL rollback actions..."
        process_rollback_stack "CRITICAL" "${CRITICAL_ROLLBACK[@]}"
    fi
    
    # 2. Normal Rollbacks
    if [[ ${#NORMAL_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Executing normal rollback actions..."
        process_rollback_stack "NORMAL" "${NORMAL_ROLLBACK[@]}"
    fi

    # 3. Cleanup Rollbacks (Removing files)
    if [[ ${#CLEANUP_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Executing cleanup actions..."
        process_rollback_stack "CLEANUP" "${CLEANUP_ROLLBACK[@]}"
    fi
    
    # Remove created files (Global list)
    if [[ ${#CREATED_FILES[@]} -gt 0 ]]; then
        for filepath in "${CREATED_FILES[@]}"; do
            if [[ -n "$filepath" && -e "$filepath" ]]; then
                log_info "Removing: ${filepath}"
                rm -rf "$filepath" 2>/dev/null || true
            fi
        done
    fi
    
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}       ROLLBACK COMPLETED              ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    log_warn "System has been restored to previous state."
}

# Trap handler for errors
error_handler() {
    local exit_code=$?
    local line_no=$1
    local command="${BASH_COMMAND}"
    
    log_error "Command failed at line ${line_no}: ${command}"
    log_error "Exit code: ${exit_code}"
    
    execute_rollback
    exit $exit_code
}

# Setup error trap
setup_error_trap() {
    trap 'error_handler ${LINENO}' ERR
}

# Disable error trap (for intentional failures)
disable_error_trap() {
    trap - ERR
}

# -----------------------------------------------------------------------------
# UTILITY FUNCTIONS
# -----------------------------------------------------------------------------

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Generate random password (alphanumeric only to avoid shell evaluation issues)
# FIXED: Proper error handling, no silent failures
generate_password() {
    local length="${1:-32}"
    local password=""
    
    # Method 1: Use /dev/urandom (preferred)
    if [[ -r /dev/urandom ]]; then
        password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$length")
    fi
    
    # Method 2: Use openssl as fallback
    if [[ -z "$password" || ${#password} -lt $length ]] && command_exists openssl; then
        password=$(openssl rand -base64 $((length * 2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$length")
    fi
    
    # Method 3: Use $RANDOM as last resort (less secure but functional)
    if [[ -z "$password" || ${#password} -lt $length ]]; then
        log_warn "Using fallback password generation (less secure)"
        local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        password=""
        for ((i=0; i<length; i++)); do
            password+="${chars:RANDOM%${#chars}:1}"
        done
    fi
    
    # Final validation
    if [[ -z "$password" || ${#password} -lt $length ]]; then
        log_error "Failed to generate secure password"
        return 1
    fi
    
    echo "$password"
}

# Generate alphanumeric string (for IDs)
generate_alphanum() {
    local length="${1:-16}"
    local result=""
    
    if command_exists openssl; then
        result=$(openssl rand -hex "$((length / 2 + 1))" 2>/dev/null | head -c "$length")
    fi
    
    if [[ -z "$result" || ${#result} -lt $length ]]; then
        result=$(generate_password "$length")
    fi
    
    echo "$result"
}

# Generate short ID for Reality (hex, 8 chars)
generate_short_id() {
    local result=""
    
    if command_exists openssl; then
        result=$(openssl rand -hex 4 2>/dev/null)
    fi
    
    if [[ -z "$result" ]]; then
        # Fallback
        result=$(printf '%08x' $((RANDOM * RANDOM)))
    fi
    
    echo "$result"
}

# Wait for service to be ready
wait_for_service() {
    local host="$1"
    local port="$2"
    local timeout="${3:-60}"
    local interval="${4:-2}"
    
    log_info "Waiting for ${host}:${port} to be ready..."
    
    local elapsed=0
    while ! nc -z "$host" "$port" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for ${host}:${port}"
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_success "${host}:${port} is ready"
    return 0
}

# Wait for HTTP endpoint
wait_for_http() {
    local url="$1"
    local timeout="${2:-120}"
    local interval="${3:-5}"
    
    log_info "Waiting for ${url} to respond..."
    
    local elapsed=0
    while ! curl -sf -o /dev/null "$url" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for ${url}"
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_success "${url} is responding"
    return 0
}

# Get current SSH port from sshd config
detect_ssh_port() {
    local ssh_port=""
    
    # Try to get from sshd_config
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    # If not found, check ss/netstat for listening sshd
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
    fi
    
    # Check current SSH connection as last resort
    if [[ -z "$ssh_port" && -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    
    # Default to 22 if still not found
    echo "${ssh_port:-22}"
}

# Get server's public IP
get_public_ip() {
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )
    
    # Try multiple services with timeout
    for service in "${services[@]}"; do
        ip=$(curl -4sf --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    # Try dig as fallback
    if command_exists dig; then
        ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1)
        if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    fi
    
    log_error "Could not determine public IP address"
    return 1
}

# Validate domain resolves to server IP
validate_domain() {
    local domain="$1"
    local server_ip="$2"
    
    local domain_ip=""
    
    if command_exists dig; then
        domain_ip=$(dig +short "$domain" A 2>/dev/null | head -1)
    elif command_exists host; then
        domain_ip=$(host "$domain" 2>/dev/null | awk '/has address/ {print $4}' | head -1)
    elif command_exists nslookup; then
        domain_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | tail -1)
    fi
    
    if [[ "$domain_ip" != "$server_ip" ]]; then
        log_warn "Domain ${domain} resolves to ${domain_ip:-<nothing>}, expected ${server_ip}"
        return 1
    fi
    
    log_success "Domain ${domain} correctly resolves to ${server_ip}"
    return 0
}

# Create directory with proper permissions
create_dir() {
    local dir="$1"
    local mode="${2:-0755}"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        register_file "$dir"
        log_debug "Created directory: ${dir} (mode: ${mode})"
    else
        log_debug "Directory already exists: ${dir}"
    fi
}

# Create file with proper permissions
create_secure_file() {
    local filepath="$1"
    local mode="${2:-0600}"
    
    touch "$filepath"
    chmod "$mode" "$filepath"
    register_file "$filepath"
    log_debug "Created secure file: ${filepath} (mode: ${mode})"
}

# Backup file if exists
backup_file() {
    local filepath="$1"
    
    if [[ -f "$filepath" ]]; then
        local backup="${filepath}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$filepath" "$backup"
        log_info "Backed up ${filepath} to ${backup}"
        register_rollback "Restore ${filepath}" "mv '$backup' '$filepath'"
        echo "$backup"
    fi
}

# Escape string for JSON
json_escape() {
    local string="$1"
    # Escape backslashes, quotes, and control characters
    printf '%s' "$string" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || \
    printf '%s' "$string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g'
}

# Check required dependencies
check_dependencies() {
    local missing=()
    local deps=("$@")
    
    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Install missing packages
install_packages() {
    local packages=("$@")
    
    log_info "Installing packages: ${packages[*]}"
    
    apt-get update -qq
    apt-get install -y -qq "${packages[@]}"
    
    INSTALLED_PACKAGES+=("${packages[@]}")
}

# Check system requirements
check_system_requirements() {
    log_step "Checking system requirements"
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        return 1
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_error "This script supports Ubuntu/Debian only. Detected: ${ID}"
        return 1
    fi
    
    log_info "Detected OS: ${PRETTY_NAME}"
    
    # Check architecture
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        log_error "Unsupported architecture: ${arch}"
        return 1
    fi
    log_info "Architecture: ${arch}"
    
    # Check RAM (minimum 1GB recommended)
    local total_ram
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram -lt 512 ]]; then
        log_warn "Low RAM detected: ${total_ram}MB. Minimum 1GB recommended."
    else
        log_info "RAM: ${total_ram}MB"
    fi
    
    # Check disk space (minimum 10GB free for Docker images)
    local free_space
    free_space=$(df -BG / | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ $free_space -lt 10 ]]; then
        log_warn "Low disk space: ${free_space}GB free. Minimum 10GB recommended for Docker images."
    else
        log_info "Free disk space: ${free_space}GB"
    fi
    
    # Check basic dependencies
    local basic_deps=(curl wget)
    for dep in "${basic_deps[@]}"; do
        if ! command_exists "$dep"; then
            log_info "Installing ${dep}..."
            apt-get update -qq && apt-get install -y -qq "$dep"
        fi
    done
    
    log_success "System requirements check passed"
}

# Confirm action from user
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi
    
    read -rp "$(echo -e "${YELLOW}${message} ${prompt}: ${NC}")" response
    response="${response:-$default}"
    
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# Print separator line
print_separator() {
    echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}"
}

# Print banner
print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  __  __                _                 
 |  \/  | __ _ _ __ ___| |__   __ _ _ __  
 | |\/| |/ _` | '__/_  | '_ \ / _` | '_ \ 
 | |  | | (_| | |  / / | |_) | (_| | | | |
 |_|  |_|\__,_|_| /___/|_.__/ \__,_|_| |_|
                                          
    VPN Server Installer (Xray Core)
EOF
    echo -e "${NC}"
    print_separator
}

# Rotate log file if too large
rotate_log() {
    local log_file="$1"
    local max_size="${2:-10485760}"  # 10MB default
    
    if [[ -f "$log_file" ]]; then
        local size
        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
        
        if [[ $size -gt $max_size ]]; then
            mv "$log_file" "${log_file}.$(date +%Y%m%d_%H%M%S)"
            gzip "${log_file}."* 2>/dev/null || true
            log_info "Log file rotated: ${log_file}"
        fi
    fi
}

# Check if installation already exists
check_existing_installation() {
    local data_dir="${1:-/opt/marzban}"
    
    if [[ -d "$data_dir" ]] && [[ -f "${data_dir}/.env" ]]; then
        log_warn "Existing Marzban installation detected at ${data_dir}"
        return 0
    fi
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^marzban$"; then
        log_warn "Existing Marzban container detected"
        return 0
    fi
    
    return 1
}
