# CLAUDE.md - AI Assistant Guide

This document provides comprehensive guidance for AI assistants working on the Marzban VPN Server Installer codebase.

## Project Overview

**Project Name:** Marzban VPN Server Installer
**Repository:** shiny-adventure
**Language:** Bash (Shell Scripting)
**Primary Purpose:** Automated installation and configuration of a VPN server based on Marzban panel with Xray/Sing-box core

### What This Project Does

This is a modular Bash script suite that automates the complete setup of a VPN server stack including:
- **Marzban Panel** (VPN management interface)
- **Docker & Docker Compose** (containerization)
- **AdGuard Home** (DNS server with ad-blocking)
- **Cloudflare WARP** (outbound proxy for geo-unblocking)
- **UFW Firewall** (security)
- **SSL Certificates** (Let's Encrypt via acme.sh)
- **Reality Protocol** (advanced VPN protocol with X25519 key generation)
- **Three VPN Profiles** with different routing strategies

### Target Environment

- **OS:** Ubuntu 22.04 LTS or Debian 11+
- **Architecture:** x86_64 or aarch64
- **Requirements:** Root access, 1GB+ RAM, 5GB+ disk space
- **DNS:** Domain pointing to server IP required

## Repository Structure

```
shiny-adventure/
├── install.sh              # Main installer orchestrator (380 lines)
├── uninstall.sh            # Clean removal script (149 lines)
├── config.env.example      # Configuration template
├── README.md               # User documentation (in Russian)
├── modules/                # Modular components
│   ├── core.sh             # Core library (405 lines)
│   ├── docker.sh           # Docker installation
│   ├── firewall.sh         # UFW configuration
│   ├── ssl.sh              # SSL certificate management
│   ├── reality.sh          # Reality protocol key generation
│   ├── warp.sh             # Cloudflare WARP setup
│   ├── adguard.sh          # AdGuard Home installation
│   ├── marzban.sh          # Marzban panel installation
│   └── marzban_api.sh      # API integration for configuration
└── .git/                   # Git repository
```

### File Purposes

| File | Purpose | Key Functions |
|------|---------|---------------|
| `install.sh` | Orchestrates entire installation workflow | `main_installation()`, `load_config()`, `pre_installation_checks()` |
| `modules/core.sh` | Core utilities, logging, error handling, rollback | `log_*()`, `register_rollback()`, `execute_rollback()`, `error_handler()` |
| `modules/docker.sh` | Docker and Docker Compose installation | `install_docker()`, `create_docker_network()` |
| `modules/firewall.sh` | UFW firewall configuration | `configure_firewall()`, `detect_ssh_port()` |
| `modules/ssl.sh` | SSL certificate acquisition (acme.sh) | `setup_ssl()`, `install_acme_sh()` |
| `modules/reality.sh` | X25519 key pair generation for Reality | `setup_reality_keys()`, `generate_x25519_keypair()` |
| `modules/warp.sh` | Cloudflare WARP integration | `setup_warp()`, `install_wgcf()` |
| `modules/adguard.sh` | AdGuard Home DNS server | `setup_adguard()`, `generate_bcrypt_hash()` |
| `modules/marzban.sh` | Marzban panel deployment | `install_marzban()`, `create_docker_compose()` |
| `modules/marzban_api.sh` | API-based VPN profile configuration | `configure_profiles_via_api()`, `init_marzban_api()` |

## Code Architecture & Patterns

### 1. Modular Design

Each module is a self-contained Bash script that can be sourced independently:

```bash
# All modules follow this pattern
source "${SCRIPT_DIR}/modules/core.sh"
source "${SCRIPT_DIR}/modules/docker.sh"
# ... etc
```

**Key Principle:** Each module handles ONE specific domain (Docker, SSL, Firewall, etc.)

### 2. Error Handling: Try/Catch Pattern

This project implements a sophisticated rollback system using Bash error traps:

```bash
# Setup at start of installation
setup_error_trap()  # Registers trap 'error_handler ${LINENO}' ERR

# During installation, register rollback actions
register_rollback "description" "command to undo"
register_file "/path/to/created/file"
register_service "service-name"

# On error, automatic rollback
execute_rollback()  # Executes all rollback actions in reverse order
```

**Critical Pattern:** Every destructive operation should register a rollback action BEFORE execution.

### 3. Configuration Management

Configuration is centralized in `config.env`:

```bash
# Load and validate configuration
load_config() {
    source "$CONFIG_FILE"
    # Validate required fields
    # Set defaults for optional fields
}
```

**Variables are NOT readonly** (changed in commit `eaf8cde`) to allow runtime modification.

### 4. Output Communication

**IMPORTANT:** Functions communicate results via `echo` statements with parseable format:

```bash
# Example from ssl.sh
echo "CERT_FILE=${cert_path}"
echo "KEY_FILE=${key_path}"

# Caller parses with eval
SSL_OUTPUT=$(setup_ssl ...)
eval "$(echo "$SSL_OUTPUT" | grep -E "^(CERT_FILE|KEY_FILE)=")"
```

**Why:** Bash functions can only return exit codes (0-255), so structured output is used for data.

### 5. Logging System

Five log levels with color coding:

```bash
log_info "General information"      # Blue
log_success "Operation succeeded"   # Green
log_warn "Warning message"          # Yellow
log_error "Error occurred"          # Red
log_debug "Debug info"              # Cyan (only if DEBUG_MODE=true)
log_step "Major installation step"  # Bold green with separator
```

All output is teed to `/var/log/marzban-installer.log`.

### 6. Security Practices

**Strict Security Rules:**
- ❌ NEVER use `chmod 777`
- ❌ NEVER use `docker stop $(docker ps -q)` (too broad)
- ✅ Always use specific container names
- ✅ Always set file permissions explicitly (0600 for secrets, 0755 for dirs)
- ✅ Generate cryptographically secure passwords with `openssl rand`
- ✅ Use bcrypt for password hashing (AdGuard)
- ✅ Auto-detect SSH port before configuring firewall
- ✅ Validate all user inputs

**Password Generation:**
```bash
generate_password() {
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 32
}
```

### 7. Bash Best Practices

```bash
# Always use at top of scripts
set -euo pipefail
# -e: exit on error
# -u: exit on undefined variable
# -o pipefail: exit on pipe failure

# Use local variables in functions
local variable_name="value"

# Quote all variables
echo "${VARIABLE}"
[[ -n "$var" ]]

# Array iteration
for item in "${array[@]}"; do
    echo "$item"
done
```

## Development Workflows

### Adding a New Module

1. Create `modules/new_module.sh`
2. Add header comment with module description
3. Source `core.sh` for utilities:
   ```bash
   source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
   ```
4. Implement main function with clear output:
   ```bash
   setup_new_feature() {
       log_step "Setting up new feature"

       # Register rollback actions
       register_rollback "Remove config" "rm -f /path/to/config"

       # Do work
       create_dir "/opt/feature"

       # Output results
       echo "FEATURE_PATH=/opt/feature"
       log_success "Feature setup complete"
   }
   ```
5. Source in `install.sh`:
   ```bash
   source "${SCRIPT_DIR}/modules/new_module.sh"
   ```
6. Call in `main_installation()` function

### Modifying Existing Functionality

1. **Read the module first** - understand existing patterns
2. **Check for rollback actions** - maintain or update them
3. **Preserve output format** - other code may parse it
4. **Test error cases** - ensure rollback works
5. **Update configuration** - add to `config.env.example` if needed
6. **Document changes** - update relevant comments

### Configuration Changes

When adding new configuration options:

1. Add to `config.env.example` with comment
2. Set default in `install.sh` (lines 46-69)
3. Add validation in `load_config()` if required
4. Document in README.md

### Common Modification Patterns

#### Changing Ports
Recent change (commit `09f7475`): AdGuard DNS port changed from 5353 to 53
- Update default in `install.sh`
- Update `config.env.example`
- Update firewall rules in `configure_firewall()`
- Update Docker configuration

#### Modifying Firewall Rules
Recent change (commit `ba9b82b`): Disabled SSH port check
- Modify `modules/firewall.sh`
- Always preserve SSH access
- Test with various SSH port configurations

#### Adjusting Output Handling
Recent change (commit `070f7ed`): Refined SSL output handling
- Ensure parseable format: `VARIABLE=value`
- Test eval parsing: `eval "$(echo "$OUTPUT" | grep pattern)"`

## Key Conventions

### 1. Naming Conventions

**Variables:**
- Global config: `UPPER_SNAKE_CASE`
- Local variables: `lower_snake_case`
- Exported variables: `export UPPER_CASE`

**Functions:**
- Action functions: `verb_noun()` (e.g., `install_docker`, `setup_ssl`)
- Helper functions: `noun_verb()` (e.g., `password_generate`)
- Boolean checks: `is_*()` or `has_*()` or `check_*()`

**Files:**
- Module files: `lowercase.sh`
- Config files: `lowercase.env` or `lowercase.conf`

### 2. Directory Structure Conventions

Installation creates standard directory structure:
```
/opt/marzban/
├── .env                    # Marzban environment variables
├── docker-compose.yml      # Docker Compose configuration
├── admin_credentials.txt   # Generated credentials (mode 0600)
├── installation_summary.txt # Installation summary (mode 0600)
├── ssl/                    # SSL certificates
├── keys/                   # Reality protocol keys
├── warp/                   # WARP configuration
├── adguard/               # AdGuard data
└── logs/                  # Application logs
```

### 3. Error Handling Conventions

**Always:**
- Register rollback actions BEFORE making changes
- Use specific error messages with context
- Return appropriate exit codes (0 = success, 1 = error)
- Log errors to stderr: `>&2`

**Example:**
```bash
setup_something() {
    local config_file="/etc/something.conf"

    # Backup existing file
    backup_file "$config_file"

    # Register rollback
    register_rollback "Remove new config" "rm -f '${config_file}'"

    # Do work
    if ! create_config "$config_file"; then
        log_error "Failed to create config at ${config_file}"
        return 1
    fi

    log_success "Config created successfully"
    return 0
}
```

### 4. Docker Conventions

- Use named containers, never auto-generated names
- Use custom networks, never default bridge
- Use compose files, not raw `docker run`
- Always specify restart policies
- Mount volumes with proper permissions

### 5. API Integration Conventions

From `marzban_api.sh`:
- Authenticate once, store token
- Use bearer token for subsequent requests
- Handle JSON with `jq`
- Validate responses before parsing
- Use `-k` flag for self-signed certificates (local-only)

## Testing & Debugging

### Debug Mode

Enable with `DEBUG_MODE="true"` in config.env:
```bash
log_debug "This only shows in debug mode"
```

### Manual Testing Checklist

1. **Pre-installation:**
   - Verify config.env is complete
   - Check system requirements
   - Verify domain DNS resolution

2. **During installation:**
   - Monitor `/var/log/marzban-installer.log`
   - Watch for rollback triggers
   - Verify each module completes

3. **Post-installation:**
   - Check Docker containers: `docker compose ps`
   - Verify services: `curl https://panel.domain:8443`
   - Test firewall: `ufw status`
   - Validate credentials in `/opt/marzban/admin_credentials.txt`

### Triggering Rollback for Testing

```bash
# Add intentional failure in module
setup_test() {
    register_rollback "Test cleanup" "echo 'Rolling back test'"
    create_dir "/tmp/test_install"
    return 1  # Force failure
}
```

### Common Issues & Solutions

**Issue:** Port already in use
**Solution:** Check with `ss -tlnp | grep :PORT`, update config or stop conflicting service

**Issue:** Domain doesn't resolve
**Solution:** Verify DNS with `dig +short domain.com`, wait for propagation

**Issue:** Docker network conflicts
**Solution:** Remove existing network: `docker network rm marzban-network`

**Issue:** SSL certificate failure
**Solution:** Check port 80 accessibility, verify domain DNS, check Let's Encrypt rate limits

## Common Tasks for AI Assistants

### Task 1: Add New VPN Profile

**Location:** `modules/marzban_api.sh` and `install.sh`

**Steps:**
1. Add configuration variables to `config.env.example`:
   ```bash
   PROFILE4_PORT="2096"
   PROFILE4_SNI="cloudflare.com"
   PROFILE4_NAME="Custom-Profile"
   ```
2. Add defaults to `install.sh` (lines 46-69)
3. Update `configure_profiles_via_api()` to handle 4th profile
4. Update firewall configuration to open new port
5. Update final summary output

### Task 2: Change Default Ports

**Affected Files:** `install.sh`, `config.env.example`, `modules/firewall.sh`

**Pattern:**
```bash
# 1. Update default in install.sh
MARZBAN_PORT="9443"  # Changed from 8443

# 2. Update example config
# 3. Test port availability check still works
# 4. Update README.md if needed
```

### Task 3: Add New Dependency Check

**Location:** `modules/core.sh` → `check_system_requirements()`

**Pattern:**
```bash
check_system_requirements() {
    # ... existing checks ...

    # Add new check
    if ! command_exists "required_tool"; then
        log_error "required_tool is not installed"
        return 1
    fi
    log_info "required_tool: $(required_tool --version)"
}
```

### Task 4: Improve Error Messages

**Best Practices:**
- Include context (what was being attempted)
- Include relevant values (paths, ports, etc.)
- Suggest remediation steps
- Log to appropriate level (error vs warning)

**Example:**
```bash
# Bad
log_error "Failed"

# Good
log_error "Failed to create directory ${data_dir}: Permission denied"
log_error "Ensure the script is run with sudo/root privileges"
```

### Task 5: Add Configuration Validation

**Location:** `install.sh` → `load_config()`

**Pattern:**
```bash
# Validate port range
if [[ "$MARZBAN_PORT" -lt 1 || "$MARZBAN_PORT" -gt 65535 ]]; then
    log_error "MARZBAN_PORT must be between 1-65535, got: ${MARZBAN_PORT}"
    exit 1
fi

# Validate email format
if [[ ! "$SSL_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    log_error "Invalid email format: ${SSL_EMAIL}"
    exit 1
fi
```

### Task 6: Update API Integration

**Location:** `modules/marzban_api.sh`

**When:** Marzban API changes or new endpoints needed

**Pattern:**
1. Check Marzban API documentation
2. Add new function following existing pattern:
   ```bash
   api_new_feature() {
       log_info "Calling new API endpoint..."
       local response
       response=$(marzban_api_request "POST" "/api/new-endpoint" '{"key":"value"}')

       if [[ -z "$response" ]]; then
           log_error "API call failed"
           return 1
       fi

       echo "$response" | jq '.'
       return 0
   }
   ```

### Task 7: Refactor for Better Error Handling

**Before:**
```bash
setup_feature() {
    mkdir /opt/feature
    touch /opt/feature/config
    chmod 600 /opt/feature/config
}
```

**After:**
```bash
setup_feature() {
    local feature_dir="/opt/feature"
    local config_file="${feature_dir}/config"

    # Register rollback
    register_rollback "Remove feature dir" "rm -rf '${feature_dir}'"

    # Create with error checking
    create_dir "$feature_dir" 0755
    create_secure_file "$config_file" 0600

    log_success "Feature directory created at ${feature_dir}"
    echo "FEATURE_DIR=${feature_dir}"
}
```

## Git Workflow

### Branch Strategy

**Current Branch:** `claude/claude-md-milnrityrhik2k5a-01WKPa8vbRsoi5J3zFsa3Vgw`

All development should occur on Claude-specific branches (`claude/*`).

### Commit Message Conventions

Based on recent commits:
- Use imperative mood: "Change", "Add", "Fix", "Enhance"
- Be specific: Include what and why
- Examples from history:
  - `Change AdGuard DNS port from 5353 to 53`
  - `Disable SSH port check in firewall script`
  - `Enhance README with Marzban VPN Installer details`

### Making Changes

1. **Understand first:** Read related code before modifying
2. **Test locally:** Verify changes don't break existing functionality
3. **Commit atomically:** One logical change per commit
4. **Push with retry:** Network errors may occur, retry with exponential backoff

```bash
git add <files>
git commit -m "Descriptive message"
git push -u origin claude/branch-name
```

### Recent Important Changes

1. **commit 09f7475:** Changed AdGuard DNS port from 5353 to 53
   - Affects: AdGuard configuration, firewall rules
   - Impact: DNS now runs on standard port

2. **commit ba9b82b:** Disabled SSH port check in firewall script
   - Affects: `modules/firewall.sh`
   - Impact: More reliable firewall setup

3. **commit eaf8cde:** Changed color variables from readonly to mutable
   - Affects: `modules/core.sh`
   - Impact: Allows runtime color customization

## Additional Resources

### External Dependencies

- **Docker:** https://docs.docker.com/
- **Marzban:** https://github.com/Gozargah/Marzban
- **Sing-box:** https://github.com/SagerNet/sing-box
- **AdGuard Home:** https://github.com/AdguardTeam/AdGuardHome
- **acme.sh:** https://github.com/acmesh-official/acme.sh
- **wgcf:** https://github.com/ViRb3/wgcf

### Useful Commands

```bash
# View installation logs
tail -f /var/log/marzban-installer.log

# Check Marzban status
cd /opt/marzban && docker compose ps

# View Marzban logs
docker logs marzban -f

# Restart services
cd /opt/marzban && docker compose restart

# Check firewall
ufw status verbose

# Test API
curl -k https://127.0.0.1:8443/api/system
```

## When to Ask for Clarification

Ask the user when:
1. Configuration values are ambiguous or missing
2. Multiple valid implementation approaches exist
3. Changes may affect production systems
4. Security implications are unclear
5. Rollback strategy is not obvious
6. API behavior is undocumented

## Summary for AI Assistants

**Key Principles:**
1. **Safety First:** Always implement rollback, never make irreversible changes without backup
2. **Modularity:** Keep modules focused and independent
3. **Security:** Follow strict security practices, never compromise for convenience
4. **Clarity:** Write clear, self-documenting code with good logging
5. **Testing:** Verify error handling paths work correctly
6. **Documentation:** Update comments and docs when changing behavior

**Before Making Changes:**
- ✅ Read and understand related code
- ✅ Check for dependencies and callers
- ✅ Plan rollback strategy
- ✅ Consider security implications
- ✅ Test error conditions

**After Making Changes:**
- ✅ Update relevant documentation
- ✅ Add/update tests if applicable
- ✅ Commit with clear message
- ✅ Verify rollback still works

---

**Last Updated:** 2025-11-30
**Codebase Version:** Based on commit `09f7475`
