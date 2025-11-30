#!/bin/bash
# =============================================================================
# MODULE: docker.sh - Docker & Docker Compose Installation
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# -----------------------------------------------------------------------------
# DOCKER INSTALLATION
# -----------------------------------------------------------------------------

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
        if ! docker compose version 2>&1 | grep -q "Docker Compose version v2"; then
            log_warn "Old docker-compose v1 detected, need v2 plugin"
            return 1
        fi
        log_info "Docker Compose is already installed: v${compose_version}"
        return 0
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
        if dpkg -l "$pkg" &>/dev/null; then
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
    
    # Download Docker GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Get OS info
    source /etc/os-release
    
    # Determine the correct repo
    local repo_url="https://download.docker.com/linux/${ID}"
    local codename="${VERSION_CODENAME:-$(lsb_release -cs)}"
    
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
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    register_rollback "Remove Docker packages" \
        "apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
}

# Configure Docker daemon
configure_docker_daemon() {
    log_info "Configuring Docker daemon..."
    
    local docker_config_dir="/etc/docker"
    local daemon_json="${docker_config_dir}/daemon.json"
    
    create_dir "$docker_config_dir"
    
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
    
    # Wait for Docker to be ready
    local retries=0
    local max_retries=30
    
    while ! docker info &>/dev/null; do
        if [[ $retries -ge $max_retries ]]; then
            log_error "Docker failed to start after ${max_retries} seconds"
            return 1
        fi
        sleep 1
        ((retries++))
    done
    
    log_success "Docker service is running"
}

# Create Docker network for Marzban
create_docker_network() {
    local network_name="${1:-marzban-network}"
    
    log_info "Creating Docker network: ${network_name}"
    
    if docker network inspect "$network_name" &>/dev/null; then
        log_info "Network ${network_name} already exists"
        return 0
    fi
    
    docker network create \
        --driver bridge \
        --subnet=172.28.0.0/16 \
        --gateway=172.28.0.1 \
        "$network_name"
    
    register_rollback "Remove Docker network ${network_name}" \
        "docker network rm '${network_name}' 2>/dev/null || true"
    
    log_success "Docker network ${network_name} created"
}

# Main Docker installation function
install_docker() {
    log_step "Installing Docker"
    
    # Check if already installed
    if check_docker_installed && check_docker_compose_installed; then
        log_success "Docker and Docker Compose are already installed"
        return 0
    fi
    
    # Remove old packages
    remove_old_docker
    
    # Install dependencies
    install_docker_dependencies
    
    # Setup repository
    setup_docker_repo
    
    # Install Docker
    install_docker_engine
    
    # Configure daemon
    configure_docker_daemon
    
    # Start service
    start_docker_service
    
    # Verify installation
    if ! check_docker_installed; then
        log_error "Docker installation failed"
        return 1
    fi
    
    if ! check_docker_compose_installed; then
        log_error "Docker Compose installation failed"
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
    
    # Run hello-world container
    if docker run --rm hello-world &>/dev/null; then
        log_success "Docker is working correctly"
        return 0
    else
        log_error "Docker verification failed"
        return 1
    fi
}
