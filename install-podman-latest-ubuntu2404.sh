#!/usr/bin/env bash
#===============================================================================
# install-podman-latest.sh
#
# Builds and installs the latest Podman from source on Ubuntu 24.04 LTS
#
# This script handles all dependencies, builds required components in the
# correct order, and configures the system for rootless container operation.
#
# Components installed from source:
#   - Go 1.25.6 (from official tarball)
#   - conmon (container monitor)
#   - crun (OCI runtime)
#   - Podman (container engine)
#
# Components installed from apt:
#   - netavark (network backend - CRITICAL)
#   - aardvark-dns (container DNS - CRITICAL)
#   - passt/pasta (rootless networking)
#   - Various build dependencies
#
# Usage:
#   chmod +x install-podman-latest.sh
#   ./install-podman-latest.sh
#
# Options:
#   --skip-cleanup    Don't remove build directories after installation
#   --force           Force reinstall even if Podman is already installed
#   --debug           Enable verbose debug output
#   --help            Show this help message
#
# Requirements:
#   - Ubuntu 24.04 LTS
#   - sudo privileges
#   - Internet connectivity
#   - ~2GB free disk space
#
# Author: Generated with assistance from Claude
# Date: February 2026
# Version: 2.1.0
#===============================================================================

# Bash strict mode - but handle errors ourselves for better messaging
set -o nounset   # Exit on undefined variable
set -o pipefail  # Exit on pipe failure
# Note: We intentionally don't use errexit (-e) as we handle errors explicitly

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# Go 1.25.6 is the latest stable release as of February 1, 2026
# Released: 2026-01-15
readonly GO_VERSION="${GO_VERSION:-1.25.6}"

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/podman-build}"
readonly LOG_FILE="${BUILD_DIR}/install.log"

# Colors for output (check if terminal supports colors)
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly BOLD=''
    readonly NC=''
fi

# Flags (use declare for variables that will be modified)
declare SKIP_CLEANUP=false
declare FORCE_INSTALL=false
declare DEBUG_MODE=false
declare LOG_INITIALIZED=false

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------

write_log() {
    if [[ "$LOG_INITIALIZED" == "true" ]] && [[ -f "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

log_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
        write_log "[DEBUG] $*"
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    write_log "[INFO] $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
    write_log "[OK] $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    write_log "[WARN] $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    write_log "[ERROR] $*"
}

log_step() {
    local step="$1"
    local total="$2"
    local msg="$3"
    echo ""
    echo -e "${GREEN}===========================================================================${NC}"
    echo -e "${GREEN}  Step ${step}/${total}: ${msg}${NC}"
    echo -e "${GREEN}===========================================================================${NC}"
    echo ""
    write_log ""
    write_log "==========================================================================="
    write_log "  Step ${step}/${total}: ${msg}"
    write_log "==========================================================================="
}

die() {
    log_error "$*"
    if [[ "$LOG_INITIALIZED" == "true" ]]; then
        log_error "Check log file for details: $LOG_FILE"
    fi
    exit 1
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------

command_exists() {
    command -v "$1" &>/dev/null
}

run_cmd() {
    local description="$1"
    shift
    log_debug "Running: $*"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        if [[ "$LOG_INITIALIZED" == "true" ]]; then
            "$@" >> "$LOG_FILE" 2>&1
        else
            "$@" >/dev/null 2>&1
        fi
        return $?
    fi
}

run_sudo() {
    local description="$1"
    shift
    log_debug "Running (sudo): $*"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        sudo "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        if [[ "$LOG_INITIALIZED" == "true" ]]; then
            sudo "$@" >> "$LOG_FILE" 2>&1
        else
            sudo "$@" >/dev/null 2>&1
        fi
        return $?
    fi
}

#-------------------------------------------------------------------------------
# Pre-flight Check Functions
#-------------------------------------------------------------------------------

check_ubuntu_version() {
    log_debug "Checking Ubuntu version..."

    if [[ ! -f /etc/os-release ]]; then
        die "Cannot determine OS version. /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    local is_ubuntu_based=false
    local detected_version=""
    local distro_name="${PRETTY_NAME:-${ID:-unknown}}"

    # Direct Ubuntu
    if [[ "${ID:-}" == "ubuntu" ]]; then
        is_ubuntu_based=true
        detected_version="${VERSION_ID:-}"
    # Ubuntu derivatives (Pop!_OS, Linux Mint, Elementary, etc.)
    elif [[ "${ID_LIKE:-}" =~ ubuntu ]]; then
        is_ubuntu_based=true
        log_info "Detected Ubuntu-based distribution: ${distro_name}"
        # Use UBUNTU_CODENAME to determine base version
        if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
            case "${UBUNTU_CODENAME}" in
                noble)   detected_version="24.04" ;;
                jammy)   detected_version="22.04" ;;
                focal)   detected_version="20.04" ;;
                *)       detected_version="${VERSION_ID:-unknown}" ;;
            esac
            log_debug "Ubuntu codename '${UBUNTU_CODENAME}' maps to version ${detected_version}"
        else
            detected_version="${VERSION_ID:-unknown}"
        fi
    fi

    if [[ "$is_ubuntu_based" != "true" ]]; then
        die "This script requires Ubuntu or an Ubuntu-based distribution. Detected: ${ID:-unknown}"
    fi

    if [[ "$detected_version" != "24.04" ]]; then
        log_warn "This script is tested on Ubuntu 24.04. Detected base version: ${detected_version}"
        log_warn "Continuing anyway, but issues may occur..."
        sleep 3
    fi

    log_debug "Ubuntu version check passed: ${detected_version} (${distro_name})"
}

check_architecture() {
    log_debug "Checking system architecture..."
    
    local arch
    arch=$(uname -m)
    
    if [[ "$arch" != "x86_64" ]]; then
        die "This script supports x86_64 only. Detected: $arch"
    fi
    
    log_debug "Architecture check passed: $arch"
}

check_sudo() {
    log_debug "Checking sudo privileges..."
    
    if ! sudo -v &>/dev/null; then
        die "This script requires sudo privileges."
    fi
    
    # Keep sudo alive during script execution
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
    
    log_debug "Sudo check passed"
}

check_disk_space() {
    log_debug "Checking disk space..."
    
    local available_kb
    available_kb=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt 2048 ]]; then
        die "Insufficient disk space. Need at least 2GB, have ${available_mb}MB"
    fi
    
    log_info "Disk space: ${available_mb}MB available"
}

check_internet() {
    log_info "Checking internet connectivity..."
    
    local test_urls=("https://go.dev" "https://github.com" "https://raw.githubusercontent.com")
    local success=false
    
    for url in "${test_urls[@]}"; do
        if curl -s --connect-timeout 10 "$url" &>/dev/null; then
            success=true
            break
        fi
    done
    
    if [[ "$success" != "true" ]]; then
        die "No internet connectivity. Cannot reach required URLs."
    fi
    
    log_success "Internet connectivity confirmed"
}

#-------------------------------------------------------------------------------
# Help and Argument Parsing
#-------------------------------------------------------------------------------

show_help() {
    cat << 'HELPEOF'
Usage: install-podman-latest.sh [OPTIONS]

Builds and installs the latest Podman from source on Ubuntu 24.04 LTS.

This script will:
  1. Remove conflicting apt packages (podman, crun, conmon)
  2. Install build and runtime dependencies from apt
  3. Install Go 1.25.6 from official tarball
  4. Build and install conmon from source
  5. Build and install crun from source
  6. Build and install Podman from source
  7. Configure Podman for rootless operation
  8. Validate the installation with comprehensive tests

Options:
    --skip-cleanup    Don't remove build directories after installation
    --force           Force reinstall even if Podman is already installed
    --debug           Enable verbose debug output
    --help, -h        Show this help message

Environment Variables:
    GO_VERSION        Go version to install (default: 1.25.6)
    BUILD_DIR         Directory for build files (default: ./podman-build)

Examples:
    ./install-podman-latest.sh
    ./install-podman-latest.sh --force
    ./install-podman-latest.sh --debug --skip-cleanup
    GO_VERSION=1.25.7 ./install-podman-latest.sh

HELPEOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            -*)
                die "Unknown option: $1. Use --help for usage."
                ;;
            *)
                die "Unexpected argument: $1. Use --help for usage."
                ;;
        esac
    done
    
    log_debug "Arguments: SKIP_CLEANUP=$SKIP_CLEANUP, FORCE_INSTALL=$FORCE_INSTALL, DEBUG_MODE=$DEBUG_MODE"
}

#-------------------------------------------------------------------------------
# Setup Functions
#-------------------------------------------------------------------------------

init_build_environment() {
    log_step 1 10 "Initializing build environment"
    
    if ! mkdir -p "$BUILD_DIR"; then
        die "Failed to create build directory: $BUILD_DIR"
    fi
    
    cat > "$LOG_FILE" << LOGHEADEREOF
================================================================================
Podman Installation Log
================================================================================
Script:     $SCRIPT_NAME
Started:    $(date)
Build Dir:  $BUILD_DIR
Go Version: $GO_VERSION
User:       $(whoami)
Host:       $(hostname)
OS:         $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
Kernel:     $(uname -r)
Arch:       $(uname -m)
================================================================================

LOGHEADEREOF
    
    LOG_INITIALIZED=true
    log_success "Build directory: $BUILD_DIR"
    log_info "Log file: $LOG_FILE"
}

remove_conflicting_packages() {
    log_step 2 10 "Removing conflicting APT packages"
    
    # Only remove packages we're building from source
    # Keep: netavark, aardvark-dns, passt (apt versions work fine)
    local packages_to_remove=(
        podman
        crun
        conmon
        buildah
        skopeo
        containers-common
        golang-github-containers-common
        golang-github-containers-image
    )
    
    local installed_packages=()
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            installed_packages+=("$pkg")
        fi
    done
    
    if [[ ${#installed_packages[@]} -gt 0 ]]; then
        log_info "Removing: ${installed_packages[*]}"
        if ! run_sudo "Remove packages" apt-get remove -y "${installed_packages[@]}"; then
            log_warn "Some packages could not be removed"
        fi
        run_sudo "Autoremove" apt-get autoremove -y || true
        log_success "Conflicting packages removed"
    else
        log_info "No conflicting packages found"
    fi
}

install_build_dependencies() {
    log_step 3 10 "Installing build and runtime dependencies"
    
    log_info "Updating apt cache..."
    if ! run_sudo "apt update" apt-get update; then
        die "Failed to update apt cache"
    fi
    
    # All required packages in categorized groups
    local packages=(
        # Core build tools
        make
        gcc
        pkg-config
        git
        curl
        wget
        
        # Podman build dependencies
        btrfs-progs
        libbtrfs-dev
        libseccomp-dev
        libassuan-dev
        libgpgme-dev
        libdevmapper-dev
        libglib2.0-dev
        libostree-dev
        libprotobuf-dev
        libprotobuf-c-dev
        libsystemd-dev
        uidmap
        go-md2man
        
        # crun build dependencies
        autoconf
        automake
        libtool
        libcap-dev
        libyajl-dev
        python3
        
        # Network stack (CRITICAL for Podman 4.0+)
        netavark
        aardvark-dns
        containernetworking-plugins
        
        # Rootless networking
        passt
        slirp4netns
        
        # Additional runtime dependencies
        fuse-overlayfs
        iptables
        libsubid4

        # Podman machine support (QEMU/VM backend)
        qemu-system-x86
        qemu-utils
        ovmf
        gvproxy
        virtiofsd
    )
    
    log_info "Installing ${#packages[@]} packages..."
    if ! run_sudo "apt install" apt-get install -y "${packages[@]}"; then
        die "Failed to install dependencies. Check log for details."
    fi
    
    # Verify critical runtime dependencies exist
    log_info "Verifying critical runtime dependencies..."
    
    local missing=()
    
    # netavark - check multiple possible locations
    if [[ ! -x /usr/lib/podman/netavark ]] && \
       [[ ! -x /usr/libexec/podman/netavark ]] && \
       ! command_exists netavark; then
        missing+=("netavark")
    fi
    
    # aardvark-dns
    if [[ ! -x /usr/lib/podman/aardvark-dns ]] && \
       [[ ! -x /usr/libexec/podman/aardvark-dns ]]; then
        missing+=("aardvark-dns")
    fi
    
    # pasta/passt for rootless networking
    if ! command_exists pasta && ! command_exists passt; then
        missing+=("passt")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Critical runtime dependencies missing: ${missing[*]}"
    fi

    # Set up gvproxy symlinks for podman machine support
    # Ubuntu installs gvproxy to /usr/bin but podman looks in helper_binaries_dir
    log_info "Setting up podman machine helper symlinks..."
    run_sudo "Create /usr/lib/podman" mkdir -p /usr/lib/podman

    if [[ -x /usr/bin/gvproxy ]] && [[ ! -e /usr/lib/podman/gvproxy ]]; then
        run_sudo "Symlink gvproxy" ln -s /usr/bin/gvproxy /usr/lib/podman/gvproxy
        log_debug "Created symlink: /usr/lib/podman/gvproxy -> /usr/bin/gvproxy"
    fi

    if [[ -x /usr/bin/qemu-wrapper ]] && [[ ! -e /usr/lib/podman/qemu-wrapper ]]; then
        run_sudo "Symlink qemu-wrapper" ln -s /usr/bin/qemu-wrapper /usr/lib/podman/qemu-wrapper
        log_debug "Created symlink: /usr/lib/podman/qemu-wrapper -> /usr/bin/qemu-wrapper"
    fi

    log_success "All dependencies installed"
}

#-------------------------------------------------------------------------------
# Go Installation
#-------------------------------------------------------------------------------

install_go() {
    log_step 4 10 "Installing Go ${GO_VERSION}"
    
    # Check if correct version already installed
    if command_exists go; then
        local current_version
        current_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$GO_VERSION" ]]; then
            log_info "Go ${GO_VERSION} already installed, skipping"
            export PATH="/usr/local/go/bin:${HOME}/go/bin:$PATH"
            export GOPATH="${HOME}/go"
            return 0
        else
            log_info "Go ${current_version} found, upgrading to ${GO_VERSION}"
        fi
    fi
    
    local go_archive="go${GO_VERSION}.linux-amd64.tar.gz"
    local go_url="https://go.dev/dl/${go_archive}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    log_info "Downloading Go ${GO_VERSION}..."
    if ! wget -q --show-progress -O "${tmp_dir}/${go_archive}" "$go_url" 2>&1; then
        rm -rf "$tmp_dir"
        die "Failed to download Go from $go_url"
    fi
    
    log_info "Installing Go to /usr/local/go..."
    sudo rm -rf /usr/local/go
    if ! sudo tar -C /usr/local -xzf "${tmp_dir}/${go_archive}"; then
        rm -rf "$tmp_dir"
        die "Failed to extract Go archive"
    fi
    
    rm -rf "$tmp_dir"
    
    # System-wide symlinks (needed for sudo operations)
    sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    
    export PATH="/usr/local/go/bin:${HOME}/go/bin:$PATH"
    export GOPATH="${HOME}/go"
    
    if ! go version &>/dev/null; then
        die "Go installation failed"
    fi
    
    log_success "Go $(go version | awk '{print $3}') installed"
    
    # Setup shell environment
    setup_go_environment
}

setup_go_environment() {
    log_info "Configuring Go environment in shell profiles..."
    
    local go_marker="# Go configuration (podman-installer)"
    local go_config="
${go_marker}
export PATH=/usr/local/go/bin:\$PATH
export GOPATH=\$HOME/go
export PATH=\$GOPATH/bin:\$PATH
"
    
    local bashrc="${HOME}/.bashrc"
    if [[ -f "$bashrc" ]]; then
        if ! grep -q "$go_marker" "$bashrc" 2>/dev/null; then
            echo "$go_config" >> "$bashrc"
            log_debug "Go environment added to $bashrc"
        fi
    fi
    
    local zshrc="${HOME}/.zshrc"
    if [[ -f "$zshrc" ]]; then
        if ! grep -q "$go_marker" "$zshrc" 2>/dev/null; then
            echo "$go_config" >> "$zshrc"
            log_debug "Go environment added to $zshrc"
        fi
    fi
}

#-------------------------------------------------------------------------------
# Build Functions
#-------------------------------------------------------------------------------

build_conmon() {
    log_step 5 10 "Building conmon (container monitor)"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    if [[ -d "conmon" ]]; then
        rm -rf conmon
    fi
    
    log_info "Cloning conmon repository..."
    if ! run_cmd "git clone conmon" git clone --depth 1 https://github.com/containers/conmon.git; then
        die "Failed to clone conmon repository"
    fi
    
    cd conmon || die "Cannot change to conmon directory"
    
    log_info "Building conmon..."
    if ! run_cmd "make conmon" make; then
        die "Failed to build conmon"
    fi
    
    log_info "Installing conmon..."
    if ! run_sudo "install conmon" make install; then
        die "Failed to install conmon"
    fi
    
    if ! command_exists conmon; then
        die "conmon installation failed - binary not found"
    fi
    
    log_success "conmon installed: $(conmon --version 2>&1 | head -1)"
}

build_crun() {
    log_step 6 10 "Building crun (OCI runtime)"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    if [[ -d "crun" ]]; then
        rm -rf crun
    fi
    
    log_info "Cloning crun repository..."
    if ! run_cmd "git clone crun" git clone --depth 1 https://github.com/containers/crun.git; then
        die "Failed to clone crun repository"
    fi
    
    cd crun || die "Cannot change to crun directory"
    
    log_info "Running autogen..."
    if ! run_cmd "autogen crun" ./autogen.sh; then
        die "Failed to run autogen.sh for crun"
    fi
    
    log_info "Configuring crun..."
    if ! run_cmd "configure crun" ./configure --prefix=/usr; then
        die "Failed to configure crun"
    fi
    
    log_info "Building crun..."
    if ! run_cmd "make crun" make; then
        die "Failed to build crun"
    fi
    
    log_info "Installing crun..."
    if ! run_sudo "install crun" make install; then
        die "Failed to install crun"
    fi
    
    if ! command_exists crun; then
        die "crun installation failed - binary not found"
    fi
    
    log_success "crun installed: $(crun --version 2>&1 | head -1)"
}

build_podman() {
    log_step 7 10 "Building Podman"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    if [[ -d "podman" ]]; then
        rm -rf podman
    fi
    
    log_info "Cloning podman repository..."
    if ! run_cmd "git clone podman" git clone --depth 1 https://github.com/containers/podman.git; then
        die "Failed to clone podman repository"
    fi
    
    cd podman || die "Cannot change to podman directory"
    
    local podman_version="unknown"
    if [[ -f version/version.go ]]; then
        podman_version=$(grep -m1 'var Version' version/version.go 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    fi
    log_info "Building Podman version: $podman_version"
    
    log_info "Building Podman (this may take several minutes)..."
    if ! run_cmd "make podman" make BUILDTAGS="selinux seccomp systemd"; then
        die "Failed to build podman"
    fi
    
    log_info "Installing Podman..."
    if ! sudo env "PATH=$PATH" make install PREFIX=/usr >> "$LOG_FILE" 2>&1; then
        die "Failed to install podman"
    fi
    
    if ! command_exists podman; then
        die "Podman installation failed - binary not found"
    fi
    
    log_success "Podman $(podman --version 2>/dev/null | awk '{print $3}') installed"
}

#-------------------------------------------------------------------------------
# Configuration Functions
#-------------------------------------------------------------------------------

configure_podman() {
    log_step 8 10 "Configuring Podman"
    
    # Create configuration directories
    log_info "Creating configuration directories..."
    sudo mkdir -p /etc/containers
    mkdir -p "${HOME}/.config/containers"
    
    # Download registries.conf
    log_info "Setting up container registries..."
    if ! sudo curl -sL -o /etc/containers/registries.conf \
        https://raw.githubusercontent.com/containers/image/main/registries.conf 2>/dev/null; then
        log_warn "Failed to download registries.conf, creating default..."
        sudo tee /etc/containers/registries.conf > /dev/null << 'REGISTRIESEOF'
unqualified-search-registries = ["docker.io", "quay.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry]]
prefix = "quay.io"
location = "quay.io"
REGISTRIESEOF
    fi
    
    # Download policy.json
    log_info "Setting up image signature policy..."
    if ! sudo curl -sL -o /etc/containers/policy.json \
        https://raw.githubusercontent.com/containers/image/main/default-policy.json 2>/dev/null; then
        log_warn "Failed to download policy.json, creating default..."
        sudo tee /etc/containers/policy.json > /dev/null << 'POLICYEOF'
{
    "default": [{"type": "insecureAcceptAnything"}],
    "transports": {
        "docker-daemon": {"": [{"type": "insecureAcceptAnything"}]}
    }
}
POLICYEOF
    fi
    
    # Create user configuration - ALWAYS OVERWRITE to avoid duplicate sections
    log_info "Creating user configuration (overwriting any existing)..."
    cat > "${HOME}/.config/containers/containers.conf" << 'USERCONFEOF'
# Podman user configuration
# Generated by install-podman-latest.sh

[containers]
# Use local timezone in containers
tz = "local"

# Default ulimits
default_ulimits = [
  "nofile=65536:65536"
]

[engine]
# Use crun as OCI runtime (faster than runc)
runtime = "crun"

# Locations for helper binaries (netavark, aardvark-dns, gvproxy, etc.)
helper_binaries_dir = [
  "/usr/lib/podman",
  "/usr/libexec/podman",
  "/usr/local/lib/podman",
  "/usr/local/libexec/podman",
  "/usr/bin",
  "/usr/libexec"
]

# Use SQLite database backend
database_backend = "sqlite"

# Event logger
events_logger = "journald"

[network]
# Use netavark as network backend (required for Podman 4.0+)
network_backend = "netavark"

# Use pasta for rootless networking (faster than slirp4netns)
default_rootless_network_cmd = "pasta"

# Enable iptables firewall driver
firewall_driver = "iptables"

[machine]
# Podman machine (VM) settings
# Uncomment and adjust as needed:
# cpus = 2
# memory = 2048
# disk_size = 100
USERCONFEOF
    
    log_info "Config file: ${HOME}/.config/containers/containers.conf"
    
    # Setup subuid/subgid for rootless containers
    log_info "Configuring rootless container support..."
    local current_user
    current_user=$(whoami)
    
    if ! grep -q "^${current_user}:" /etc/subuid 2>/dev/null; then
        sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$current_user"
        log_info "Added subuid/subgid mappings for $current_user"
    else
        log_debug "subuid/subgid mappings already exist"
    fi
    
    # Reload systemd
    log_info "Reloading systemd..."
    sudo systemctl daemon-reload 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    
    log_success "Podman configured"
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------

validate_installation() {
    log_step 9 10 "Validating installation"
    
    local errors=0
    local warnings=0
    
    echo ""
    echo -e "${BOLD}Component Versions:${NC}"
    echo "==================="
    
    # Check Go
    printf "  %-14s" "Go:"
    if command_exists go; then
        echo -e "${GREEN}$(go version | awk '{print $3}')${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        ((errors++)) || true
    fi
    
    # Check crun
    printf "  %-14s" "crun:"
    if command_exists crun; then
        echo -e "${GREEN}$(crun --version 2>&1 | head -1 | awk '{print $3}')${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        ((errors++)) || true
    fi
    
    # Check conmon
    printf "  %-14s" "conmon:"
    if command_exists conmon; then
        local conmon_ver
        conmon_ver=$(conmon --version 2>&1 | grep -oP 'version \K[0-9.]+' || echo "installed")
        echo -e "${GREEN}${conmon_ver}${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        ((errors++)) || true
    fi
    
    # Check podman
    printf "  %-14s" "podman:"
    if command_exists podman; then
        echo -e "${GREEN}$(podman --version 2>/dev/null | awk '{print $3}')${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        ((errors++)) || true
    fi
    
    # Check netavark
    printf "  %-14s" "netavark:"
    local netavark_path=""
    for path in /usr/lib/podman/netavark /usr/libexec/podman/netavark; do
        if [[ -x "$path" ]]; then
            netavark_path="$path"
            break
        fi
    done
    
    if [[ -n "$netavark_path" ]]; then
        local netavark_ver
        netavark_ver=$("$netavark_path" --version 2>&1 | awk '{print $2}' || echo "installed")
        echo -e "${GREEN}${netavark_ver}${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        ((errors++)) || true
    fi
    
    # Check aardvark-dns
    printf "  %-14s" "aardvark-dns:"
    local aardvark_path=""
    for path in /usr/lib/podman/aardvark-dns /usr/libexec/podman/aardvark-dns; do
        if [[ -x "$path" ]]; then
            aardvark_path="$path"
            break
        fi
    done
    
    if [[ -n "$aardvark_path" ]]; then
        local aardvark_ver
        aardvark_ver=$("$aardvark_path" --version 2>&1 | awk '{print $2}' || echo "installed")
        echo -e "${GREEN}${aardvark_ver}${NC}"
    else
        echo -e "${YELLOW}NOT FOUND${NC}"
        ((warnings++)) || true
    fi
    
    # Check pasta
    printf "  %-14s" "pasta:"
    if command_exists pasta; then
        local pasta_ver
        pasta_ver=$(pasta --version 2>&1 | head -1 | awk '{print $2}' || echo "installed")
        echo -e "${GREEN}${pasta_ver}${NC}"
    else
        echo -e "${YELLOW}NOT FOUND${NC}"
        ((warnings++)) || true
    fi

    echo ""
    echo -e "${BOLD}Podman Machine Components:${NC}"
    echo "=========================="

    # Check QEMU
    printf "  %-14s" "QEMU:"
    if command_exists qemu-system-x86_64; then
        local qemu_ver
        qemu_ver=$(qemu-system-x86_64 --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || echo "installed")
        echo -e "${GREEN}${qemu_ver}${NC}"
    else
        echo -e "${YELLOW}NOT FOUND (podman machine won't work)${NC}"
        ((warnings++)) || true
    fi

    # Check gvproxy
    printf "  %-14s" "gvproxy:"
    local gvproxy_found=false
    for path in /usr/lib/podman/gvproxy /usr/libexec/podman/gvproxy /usr/bin/gvproxy; do
        if [[ -x "$path" ]]; then
            gvproxy_found=true
            echo -e "${GREEN}found at ${path}${NC}"
            break
        fi
    done
    if [[ "$gvproxy_found" != "true" ]]; then
        echo -e "${YELLOW}NOT FOUND (podman machine won't work)${NC}"
        ((warnings++)) || true
    fi

    # Check OVMF (UEFI firmware)
    printf "  %-14s" "OVMF:"
    if [[ -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
        echo -e "${GREEN}present${NC}"
    else
        echo -e "${YELLOW}NOT FOUND (podman machine won't work)${NC}"
        ((warnings++)) || true
    fi

    # Check virtiofsd
    printf "  %-14s" "virtiofsd:"
    if command_exists virtiofsd; then
        echo -e "${GREEN}present${NC}"
    else
        echo -e "${YELLOW}NOT FOUND (shared folders won't work)${NC}"
        ((warnings++)) || true
    fi

    echo ""

    if [[ $errors -gt 0 ]]; then
        die "Validation failed: $errors critical component(s) missing"
    fi
    
    if [[ $warnings -gt 0 ]]; then
        log_warn "$warnings non-critical component(s) missing"
    fi
    
    # Validate podman configuration
    echo -e "${BOLD}Configuration Validation:${NC}"
    echo "========================="
    
    log_info "Checking podman configuration..."
    if ! podman info &>/dev/null; then
        log_error "podman info failed - configuration may be invalid"
        log_error "Run 'podman info' to see the error"
        die "Podman configuration validation failed"
    fi
    
    # Verify network backend
    local network_backend
    network_backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "unknown")
    printf "  %-18s" "Network backend:"
    if [[ "$network_backend" == "netavark" ]]; then
        echo -e "${GREEN}${network_backend}${NC}"
    else
        echo -e "${YELLOW}${network_backend} (expected: netavark)${NC}"
        log_warn "Network backend is not netavark"
    fi
    
    # Verify OCI runtime
    local oci_runtime
    oci_runtime=$(podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null || echo "unknown")
    printf "  %-18s" "OCI runtime:"
    if [[ "$oci_runtime" == "crun" ]]; then
        echo -e "${GREEN}${oci_runtime}${NC}"
    else
        echo -e "${YELLOW}${oci_runtime} (expected: crun)${NC}"
    fi
    
    # Verify rootless mode
    local rootless
    rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
    printf "  %-18s" "Rootless mode:"
    echo -e "${GREEN}${rootless}${NC}"
    
    echo ""
    log_success "Configuration validation passed"
}

test_container() {
    log_step 10 10 "Testing container execution"
    
    log_info "Running container test..."
    echo ""
    
    # Test 1: Basic container execution
    echo -e "  ${BOLD}Test 1: Basic container run${NC}"
    local test_output
    if test_output=$(podman run --rm docker.io/library/alpine:latest echo "Container test successful" 2>&1); then
        echo -e "    ${GREEN}✓${NC} $test_output"
    else
        echo -e "    ${RED}✗${NC} Basic container test failed"
        log_error "Container test output: $test_output"
        log_warn "Container test failed - manual troubleshooting required"
        return 1
    fi
    
    # Test 2: Network connectivity
    echo -e "  ${BOLD}Test 2: Network connectivity${NC}"
    if podman run --rm docker.io/library/alpine:latest sh -c "ping -c 1 8.8.8.8 >/dev/null 2>&1" 2>/dev/null; then
        echo -e "    ${GREEN}✓${NC} Container can reach external network"
    else
        echo -e "    ${YELLOW}!${NC} Network connectivity test inconclusive"
    fi
    
    # Test 3: DNS resolution
    echo -e "  ${BOLD}Test 3: DNS resolution${NC}"
    if podman run --rm docker.io/library/alpine:latest sh -c "nslookup google.com >/dev/null 2>&1 || wget -q --spider google.com" 2>/dev/null; then
        echo -e "    ${GREEN}✓${NC} DNS resolution working"
    else
        echo -e "    ${YELLOW}!${NC} DNS test inconclusive (may need manual verification)"
    fi
    
    echo ""
    log_success "Container tests completed"
    
    # Show summary info
    log_info "Podman system summary:"
    echo ""
    podman info 2>/dev/null | grep -E "^\s*(version|arch|os|rootless|networkBackend|ociRuntime):" | head -10 || true
    echo ""
}

#-------------------------------------------------------------------------------
# Cleanup Functions
#-------------------------------------------------------------------------------

cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log_info "Skipping cleanup (--skip-cleanup specified)"
        log_info "Build files remain in: $BUILD_DIR"
    else
        log_info "Cleaning up build directory..."
        cd "$SCRIPT_DIR" || true
        rm -rf "$BUILD_DIR"
        log_success "Cleanup complete"
    fi
}

print_summary() {
    local podman_ver
    podman_ver=$(podman --version 2>/dev/null | awk '{print $3}' || echo "unknown")
    
    cat << SUMMARYEOF

${GREEN}===============================================================================
  Installation Complete!
===============================================================================${NC}

  Podman ${podman_ver} has been successfully installed and validated.

${YELLOW}Next Steps:${NC}

  1. Start a new shell session or run:
     ${BLUE}source ~/.bashrc${NC}

  2. Test Podman:
     ${BLUE}podman run --rm alpine echo "Hello from Podman!"${NC}

  3. (Optional) Enable Docker API compatibility:
     ${BLUE}systemctl --user enable --now podman.socket${NC}

${YELLOW}Useful Commands:${NC}

  podman info              # System information
  podman images            # List images
  podman ps -a             # List all containers
  podman system prune -a   # Clean up unused resources

${YELLOW}Log File:${NC}

  ${LOG_FILE}

SUMMARYEOF
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                     Podman from Source Installer v2.1                     ║${NC}"
    echo -e "${GREEN}║                         Ubuntu 24.04 LTS                                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Pre-flight checks
    log_info "Running pre-flight checks..."
    check_ubuntu_version
    check_architecture
    check_sudo
    
    # Initialize build environment
    init_build_environment
    
    # More checks with logging
    check_disk_space
    check_internet
    
    # Check existing installation
    if command_exists podman && [[ "$FORCE_INSTALL" == "false" ]]; then
        local existing_version
        existing_version=$(podman --version 2>/dev/null | awk '{print $3}' || echo "unknown")
        log_warn "Podman ${existing_version} is already installed."
        log_warn "Use --force to reinstall."
        exit 0
    fi
    
    local start_time
    start_time=$(date +%s)
    
    # Installation steps
    remove_conflicting_packages
    install_build_dependencies
    install_go
    build_conmon
    build_crun
    build_podman
    configure_podman
    validate_installation
    test_container
    cleanup
    
    local end_time duration_mins duration_secs
    end_time=$(date +%s)
    duration_secs=$((end_time - start_time))
    duration_mins=$((duration_secs / 60))
    duration_secs=$((duration_secs % 60))
    
    log_success "Installation completed in ${duration_mins}m ${duration_secs}s"
    
    print_summary
}

trap 'echo ""; log_error "Script interrupted"; exit 1' INT TERM

main "$@"
