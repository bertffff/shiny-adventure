#!/bin/bash
# =============================================================================
# MODULE: docker.sh - Docker & Docker Compose Installation
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# DOCKER INSTALLATION
# -----------------------------------------------------------------------------

# Default subnet for Marzban network
readonly DEFAULT_SUBNET="172.28.0.0/16"
readonly DEFAULT_GATEWAY="172.28.0.1"

# Check if Docker is installed and running
check_docker_installed() {
    if command_exists docker && docker info &>/dev/null; then
        local docker_version
        docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "Docker is already installed: v${docker_version}"
        return 0
    fi
    return 1
}

# Check if Docker Compose is installed
check_docker_compose_installed() {
    if docker compose version &>/dev/null; then
        local compose_version
        compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        
        # Check for v2
        if docker compose version 2>&1 | grep -qE "Docker Compose version v[2-9]"; then
            log_info "Docker Compose is already installed: v${compose_version}"
            return 0
        else
            log_warn "Old docker-compose v1 detected, need v2 plugin"
            return 1
        fi
    fi
    return 1
}

# Remove old Docker packages
remove_old_docker() {
    log_info "Removing old Docker packages if present..."
    
    local old_packages=(
        docker
        docker-engine
        docker.io
        containerd
        runc
        docker-compose
    )
    
    for pkg in "${old_packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            apt-get remove -y "$pkg" &>/dev/null || true
        fi
    done
}

# Install Docker dependencies
install_docker_dependencies() {
    log_info "Installing Docker dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common
}

# Setup Docker repository
setup_docker_repo() {
    log_info "Setting up Docker repository..."
    
    # Create keyrings directory
    install -m 0755 -d /etc/apt/keyrings
    
    # Download Docker GPG key with timeout
    if ! timeout 30 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg; then
        log_error "Failed to download Docker GPG key"
        return 1
    fi
    
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg < /tmp/docker.gpg
    rm -f /tmp/docker.gpg
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Get OS info
    source /etc/os-release
    
    # Determine the correct repo
    local repo_url="https://download.docker.com/linux/${ID}"
    local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo "jammy")}"
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${repo_url} ${codename} stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    register_file "/etc/apt/sources.list.d/docker.list"
    register_file "/etc/apt/keyrings/docker.gpg"
}

# Install Docker Engine
install_docker_engine() {
    log_info "Installing Docker Engine..."
    
    apt-get update -qq
    
    if ! apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; then
        log_error "Failed to install Docker packages"
        return 1
    fi
    
    register_rollback "Remove Docker packages" \
        "apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" \
        "normal"
}

# Configure Docker daemon
configure_docker_daemon() {
    log_info "Configuring Docker daemon..."
    
    local docker_config_dir="/etc/docker"
    local daemon_json="${docker_config_dir}/daemon.json"
    
    create_dir "$docker_config_dir"
    
    # Backup existing config
    if [[ -f "$daemon_json" ]]; then
        backup_file "$daemon_json"
    fi
    
    # Create daemon.json with sensible defaults
    cat > "$daemon_json" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "userland-proxy": false,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 65536,
            "Soft": 65536
        }
    }
}
EOF
    
    chmod 0644 "$daemon_json"
    register_file "$daemon_json"
}

# Start and enable Docker service
start_docker_service() {
    log_info "Starting Docker service..."
    
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
    
    register_service "docker"
    
    # Wait for Docker to be ready with timeout
    local retries=0
    local max_retries=30
    
    while ! docker info &>/dev/null; do
        if [[ $retries -ge $max_retries ]]; then
            log_error "Docker failed to start after ${max_retries} seconds"
            journalctl -u docker --no-pager -n 20
            return 1
        fi
        sleep 1
        ((retries++))
    done
    
    log_success "Docker service is running"
}

# Check if subnet conflicts with existing networks
check_subnet_conflict() {
    local subnet="$1"
    local subnet_base
    
    # Extract base network (e.g., 172.28 from 172.28.0.0/16)
    subnet_base=$(echo "$subnet" | cut -d'.' -f1-2)
    
    # Check existing Docker networks
    local existing_subnets
    existing_subnets=$(docker network ls -q 2>/dev/null | xargs -I {} docker network inspect {} --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    
    for existing in $existing_subnets; do
        if [[ -n "$existing" ]]; then
            local existing_base
            existing_base=$(echo "$existing" | cut -d'.' -f1-2)
            
            if [[ "$subnet_base" == "$existing_base" ]]; then
                log_warn "Subnet conflict detected: ${subnet} overlaps with existing ${existing}"
                return 1
            fi
        fi
    done
    
    # Check system routes
    if ip route show 2>/dev/null | grep -q "^${subnet_base}"; then
        log_warn "Subnet ${subnet} may conflict with system routes"
        return 1
    fi
    
    return 0
}

# Find available subnet
find_available_subnet() {
    local subnets=(
        "172.28.0.0/16"
        "172.29.0.0/16"
        "172.30.0.0/16"
        "172.31.0.0/16"
        "10.100.0.0/16"
        "10.200.0.0/16"
    )
    
    for subnet in "${subnets[@]}"; do
        if check_subnet_conflict "$subnet"; then
            echo "$subnet"
            return 0
        fi
    done
    
    # If all fail, return default and hope for the best
    log_warn "Could not find non-conflicting subnet, using default"
    echo "$DEFAULT_SUBNET"
}

# Create Docker network for Marzban
create_docker_network() {
    local network_name="${1:-marzban-network}"
    
    log_info "Creating Docker network: ${network_name}"
    
    # Check if network already exists
    if docker network inspect "$network_name" &>/dev/null; then
        log_info "Network ${network_name} already exists"
        return 0
    fi
    
    # Find available subnet
    local subnet
    subnet=$(find_available_subnet)
    
    # Extract gateway from subnet
    local gateway
    gateway=$(echo "$subnet" | sed 's/0\.0\/16/0.1/')
    
    log_info "Using subnet: ${subnet}, gateway: ${gateway}"
    
    if ! docker network create \
        --driver bridge \
        --subnet="$subnet" \
        --gateway="$gateway" \
        "$network_name"; then
        log_error "Failed to create Docker network"
        return 1
    fi
    
    register_rollback "Remove Docker network ${network_name}" \
        "docker network rm '${network_name}' 2>/dev/null || true" \
        "normal"
    
    log_success "Docker network ${network_name} created with subnet ${subnet}"
}

# Verify Docker disk space
check_docker_disk_space() {
    local required_gb="${1:-5}"
    
    # Get Docker root directory
    local docker_root
    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
    
    # Get free space on Docker partition
    local free_space
    free_space=$(df -BG "$docker_root" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
    
    if [[ -n "$free_space" && "$free_space" -lt "$required_gb" ]]; then
        log_warn "Low disk space for Docker: ${free_space}GB free, ${required_gb}GB recommended"
        return 1
    fi
    
    log_info "Docker disk space OK: ${free_space}GB free"
    return 0
}

# Main Docker installation function
install_docker() {
    log_step "Installing Docker"
    
    # Check if already installed
    if check_docker_installed && check_docker_compose_installed; then
        log_success "Docker and Docker Compose are already installed"
        
        # Still check disk space
        check_docker_disk_space 5
        
        return 0
    fi
    
    # Check disk space before installation
    local free_space
    free_space=$(df -BG / | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ "$free_space" -lt 5 ]]; then
        log_error "Insufficient disk space for Docker installation: ${free_space}GB free"
        return 1
    fi
    
    # Remove old packages
    remove_old_docker
    
    # Install dependencies
    install_docker_dependencies
    
    # Setup repository
    if ! setup_docker_repo; then
        log_error "Failed to setup Docker repository"
        return 1
    fi
    
    # Install Docker
    if ! install_docker_engine; then
        log_error "Failed to install Docker engine"
        return 1
    fi
    
    # Configure daemon
    configure_docker_daemon
    
    # Start service
    if ! start_docker_service; then
        log_error "Failed to start Docker service"
        return 1
    fi
    
    # Verify installation
    if ! check_docker_installed; then
        log_error "Docker installation verification failed"
        return 1
    fi
    
    if ! check_docker_compose_installed; then
        log_error "Docker Compose installation verification failed"
        return 1
    fi
    
    log_success "Docker installation completed successfully"
    
    # Print versions
    echo ""
    docker --version
    docker compose version
    echo ""
}

# Verify Docker is working
verify_docker() {
    log_info "Verifying Docker installation..."
    
    # Run hello-world container with timeout
    if timeout 60 docker run --rm hello-world &>/dev/null; then
        log_success "Docker is working correctly"
        return 0
    else
        log_error "Docker verification failed"
        return 1
    fi
}

# Clean up unused Docker resources
docker_cleanup() {
    log_info "Cleaning up unused Docker resources..."
    
    # Remove unused containers
    docker container prune -f &>/dev/null || true
    
    # Remove unused images
    docker image prune -f &>/dev/null || true
    
    # Remove unused volumes
    docker volume prune -f &>/dev/null || true
    
    # Remove unused networks
    docker network prune -f &>/dev/null || true
    
    log_success "Docker cleanup completed"
}

# Get Docker system info
docker_info() {
    echo "=== Docker Info ==="
    docker info 2>/dev/null | grep -E "(Server Version|Storage Driver|Docker Root Dir|Total Memory|CPUs)"
    echo ""
    echo "=== Docker Disk Usage ==="
    docker system df 2>/dev/null || true
}
