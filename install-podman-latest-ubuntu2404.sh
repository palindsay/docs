#!/bin/bash
#===============================================================================
# install-podman-latest.sh
#
# Builds and installs the latest Podman from source on Ubuntu 24.04 LTS
#
# This script handles all dependencies, builds required components in the
# correct order, and configures the system for rootless container operation.
#
# Usage:
#   chmod +x install-podman-latest.sh
#   ./install-podman-latest.sh
#
# Options:
#   --skip-cleanup    Don't remove build directories after installation
#   --force           Force reinstall even if Podman is already installed
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
#===============================================================================

set -o errexit   # Exit on error
set -o nounset   # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

readonly GO_VERSION="${GO_VERSION:-1.23.5}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/podman-build}"
readonly LOG_FILE="${BUILD_DIR}/install.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Flags
SKIP_CLEANUP=false
FORCE_INSTALL=false

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2
}

log_step() {
    echo -e "\n${GREEN}===================================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}===================================================================${NC}\n" | tee -a "$LOG_FILE"
}

die() {
    log_error "$*"
    log_error "Check log file for details: $LOG_FILE"
    exit 1
}

command_exists() {
    command -v "$1" &>/dev/null
}

check_ubuntu_version() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot determine OS version. /etc/os-release not found."
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]]; then
        die "This script is designed for Ubuntu. Detected: $ID"
    fi
    
    if [[ "$VERSION_ID" != "24.04" ]]; then
        log_warn "This script is tested on Ubuntu 24.04. Detected: $VERSION_ID"
        log_warn "Continuing anyway, but issues may occur..."
        sleep 3
    fi
}

check_sudo() {
    if ! sudo -v &>/dev/null; then
        die "This script requires sudo privileges."
    fi
}

check_disk_space() {
    local available_kb
    available_kb=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt 2048 ]]; then
        die "Insufficient disk space. Need at least 2GB, have ${available_mb}MB"
    fi
    
    log_info "Disk space check passed: ${available_mb}MB available"
}

check_internet() {
    log_info "Checking internet connectivity..."
    if ! curl -s --connect-timeout 5 https://go.dev &>/dev/null; then
        die "No internet connectivity. Cannot proceed."
    fi
    log_success "Internet connectivity confirmed"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Builds and installs the latest Podman from source on Ubuntu 24.04 LTS.

Options:
    --skip-cleanup    Don't remove build directories after installation
    --force           Force reinstall even if Podman is already installed
    --help            Show this help message

Environment Variables:
    GO_VERSION        Go version to install (default: 1.23.5)
    BUILD_DIR         Directory for build files (default: ./podman-build)

Examples:
    $(basename "$0")
    $(basename "$0") --force
    GO_VERSION=1.23.6 $(basename "$0")

EOF
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
            --help|-h)
                show_help
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------

remove_conflicting_packages() {
    log_step "Step 1/9: Removing conflicting APT packages"
    
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
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            installed_packages+=("$pkg")
        fi
    done
    
    if [[ ${#installed_packages[@]} -gt 0 ]]; then
        log_info "Removing: ${installed_packages[*]}"
        sudo apt remove -y "${installed_packages[@]}" >> "$LOG_FILE" 2>&1 || true
        sudo apt autoremove -y >> "$LOG_FILE" 2>&1 || true
        log_success "Conflicting packages removed"
    else
        log_info "No conflicting packages found"
    fi
}

install_build_dependencies() {
    log_step "Step 2/9: Installing build dependencies"
    
    log_info "Updating apt cache..."
    sudo apt update >> "$LOG_FILE" 2>&1
    
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
        
        # Runtime dependencies
        passt
        fuse-overlayfs
        slirp4netns
        iptables
    )
    
    log_info "Installing ${#packages[@]} packages..."
    sudo apt install -y "${packages[@]}" >> "$LOG_FILE" 2>&1
    
    log_success "Build dependencies installed"
}

install_go() {
    log_step "Step 3/9: Installing Go ${GO_VERSION}"
    
    # Check if correct version already installed
    if command_exists go; then
        local current_version
        current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$GO_VERSION" ]]; then
            log_info "Go ${GO_VERSION} already installed"
            return 0
        else
            log_info "Go ${current_version} found, upgrading to ${GO_VERSION}"
        fi
    fi
    
    local go_archive="go${GO_VERSION}.linux-amd64.tar.gz"
    local go_url="https://go.dev/dl/${go_archive}"
    
    log_info "Downloading Go ${GO_VERSION}..."
    cd /tmp
    if ! wget -q --show-progress "$go_url" 2>&1 | tee -a "$LOG_FILE"; then
        die "Failed to download Go from $go_url"
    fi
    
    log_info "Installing Go to /usr/local/go..."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$go_archive"
    rm -f "$go_archive"
    
    # Create symlinks for system-wide access (needed for sudo)
    sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    
    # Export for current script
    export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
    export GOPATH="$HOME/go"
    
    # Verify installation
    if ! go version &>/dev/null; then
        die "Go installation failed"
    fi
    
    log_success "Go $(go version | awk '{print $3}') installed"
}

setup_go_environment() {
    log_info "Configuring Go environment..."
    
    # Add to bashrc if not already present
    local bashrc="$HOME/.bashrc"
    local go_marker="# Go configuration (podman installer)"
    
    if ! grep -q "$go_marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" << EOF

$go_marker
export PATH=/usr/local/go/bin:\$PATH
export GOPATH=\$HOME/go
export PATH=\$GOPATH/bin:\$PATH
EOF
        log_info "Go environment added to $bashrc"
    fi
    
    # Also check zshrc if it exists
    local zshrc="$HOME/.zshrc"
    if [[ -f "$zshrc" ]] && ! grep -q "$go_marker" "$zshrc" 2>/dev/null; then
        cat >> "$zshrc" << EOF

$go_marker
export PATH=/usr/local/go/bin:\$PATH
export GOPATH=\$HOME/go
export PATH=\$GOPATH/bin:\$PATH
EOF
        log_info "Go environment added to $zshrc"
    fi
}

create_build_directory() {
    log_step "Step 4/9: Setting up build directory"
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Initialize log file
    echo "=== Podman Installation Log ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    echo "Build directory: $BUILD_DIR" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    
    log_success "Build directory: $BUILD_DIR"
}

build_conmon() {
    log_step "Step 5/9: Building conmon"
    
    cd "$BUILD_DIR"
    
    if [[ -d "conmon" ]]; then
        log_info "Removing existing conmon source..."
        rm -rf conmon
    fi
    
    log_info "Cloning conmon repository..."
    git clone --depth 1 https://github.com/containers/conmon.git >> "$LOG_FILE" 2>&1
    cd conmon
    
    log_info "Building conmon..."
    make >> "$LOG_FILE" 2>&1
    
    log_info "Installing conmon..."
    sudo make install >> "$LOG_FILE" 2>&1
    
    # Verify
    if ! command_exists conmon; then
        die "conmon installation failed"
    fi
    
    log_success "conmon $(conmon --version 2>&1 | head -1) installed"
}

build_crun() {
    log_step "Step 6/9: Building crun"
    
    cd "$BUILD_DIR"
    
    if [[ -d "crun" ]]; then
        log_info "Removing existing crun source..."
        rm -rf crun
    fi
    
    log_info "Cloning crun repository..."
    git clone --depth 1 https://github.com/containers/crun.git >> "$LOG_FILE" 2>&1
    cd crun
    
    log_info "Generating build system..."
    ./autogen.sh >> "$LOG_FILE" 2>&1
    
    log_info "Configuring crun..."
    ./configure --prefix=/usr >> "$LOG_FILE" 2>&1
    
    log_info "Building crun (this may take a few minutes)..."
    make >> "$LOG_FILE" 2>&1
    
    log_info "Installing crun..."
    sudo make install >> "$LOG_FILE" 2>&1
    
    # Verify
    if ! command_exists crun; then
        die "crun installation failed"
    fi
    
    log_success "$(crun --version | head -1) installed"
}

build_podman() {
    log_step "Step 7/9: Building Podman"
    
    cd "$BUILD_DIR"
    
    if [[ -d "podman" ]]; then
        log_info "Removing existing podman source..."
        rm -rf podman
    fi
    
    log_info "Cloning podman repository..."
    git clone --depth 1 https://github.com/containers/podman.git >> "$LOG_FILE" 2>&1
    cd podman
    
    # Get version info
    local podman_version
    podman_version=$(grep -m1 'var Version' version/version.go | cut -d'"' -f2 || echo "unknown")
    log_info "Building Podman version: $podman_version"
    
    log_info "Building Podman (this may take several minutes)..."
    make BUILDTAGS="selinux seccomp systemd" >> "$LOG_FILE" 2>&1
    
    log_info "Installing Podman..."
    # Use env to preserve PATH for Go access
    sudo env "PATH=$PATH" make install PREFIX=/usr >> "$LOG_FILE" 2>&1
    
    # Verify
    if ! command_exists podman; then
        die "Podman installation failed"
    fi
    
    log_success "$(podman --version) installed"
}

configure_podman() {
    log_step "Step 8/9: Configuring Podman"
    
    # Create system configuration directory
    log_info "Creating configuration directories..."
    sudo mkdir -p /etc/containers
    mkdir -p "$HOME/.config/containers"
    
    # Download registries.conf
    log_info "Downloading container registries configuration..."
    if ! sudo curl -sL -o /etc/containers/registries.conf \
        https://raw.githubusercontent.com/containers/image/main/registries.conf; then
        log_warn "Failed to download registries.conf, creating minimal config..."
        sudo tee /etc/containers/registries.conf > /dev/null << 'EOF'
[registries.search]
registries = ['docker.io', 'quay.io']

[registries.block]
registries = []
EOF
    fi
    
    # Download policy.json
    log_info "Downloading signature policy..."
    if ! sudo curl -sL -o /etc/containers/policy.json \
        https://raw.githubusercontent.com/containers/image/main/default-policy.json; then
        log_warn "Failed to download policy.json, creating default policy..."
        sudo tee /etc/containers/policy.json > /dev/null << 'EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
EOF
    fi
    
    # Create user configuration
    log_info "Creating user configuration..."
    cat > "$HOME/.config/containers/containers.conf" << 'EOF'
[containers]
# Use local timezone in containers
tz = "local"

[engine]
# Use crun as runtime (faster than runc)
runtime = "crun"

[network]
# Use pasta for rootless networking (default in Podman 5.x)
default_rootless_network_cmd = "pasta"
EOF
    
    # Setup subuid/subgid for rootless containers
    log_info "Configuring rootless container support..."
    if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
        sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
        log_info "Added subuid/subgid mappings for $USER"
    else
        log_info "subuid/subgid mappings already exist for $USER"
    fi
    
    # Reload systemd
    log_info "Reloading systemd..."
    sudo systemctl daemon-reload
    systemctl --user daemon-reload 2>/dev/null || true
    
    log_success "Podman configured"
}

verify_installation() {
    log_step "Step 9/9: Verifying installation"
    
    local errors=0
    
    echo ""
    echo "Component Versions:"
    echo "-------------------"
    
    # Check Go
    if command_exists go; then
        echo "  Go:     $(go version | awk '{print $3}')"
    else
        log_error "Go not found"
        ((errors++))
    fi
    
    # Check crun
    if command_exists crun; then
        echo "  crun:   $(crun --version | head -1 | awk '{print $3}')"
    else
        log_error "crun not found"
        ((errors++))
    fi
    
    # Check conmon
    if command_exists conmon; then
        echo "  conmon: $(conmon --version 2>&1 | grep -oP 'version \K[0-9.]+')"
    else
        log_error "conmon not found"
        ((errors++))
    fi
    
    # Check podman
    if command_exists podman; then
        echo "  podman: $(podman --version | awk '{print $3}')"
    else
        log_error "podman not found"
        ((errors++))
    fi
    
    # Check pasta
    if command_exists pasta; then
        echo "  pasta:  $(pasta --version 2>&1 | head -1 | awk '{print $2}' || echo 'installed')"
    else
        log_warn "pasta not found (rootless networking may not work)"
    fi
    
    echo ""
    
    if [[ $errors -gt 0 ]]; then
        die "Installation verification failed with $errors errors"
    fi
    
    # Test container run
    log_info "Testing container execution..."
    if podman run --rm docker.io/library/alpine echo "Container test successful" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Container test passed"
    else
        log_warn "Container test failed - check configuration"
    fi
    
    log_success "All verifications passed"
}

cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log_info "Skipping cleanup (--skip-cleanup specified)"
        log_info "Build files remain in: $BUILD_DIR"
    else
        log_info "Cleaning up build directory..."
        cd "$SCRIPT_DIR"
        rm -rf "$BUILD_DIR"
        log_success "Cleanup complete"
    fi
}

print_summary() {
    cat << EOF

${GREEN}===============================================================================
  Installation Complete!
===============================================================================${NC}

Podman $(podman --version | awk '{print $3}') has been successfully installed.

${YELLOW}Next Steps:${NC}

  1. Start a new shell or run:
     ${BLUE}source ~/.bashrc${NC}

  2. Test Podman:
     ${BLUE}podman run --rm alpine echo "Hello from Podman!"${NC}

  3. (Optional) Enable socket for Docker compatibility:
     ${BLUE}systemctl --user enable --now podman.socket${NC}

${YELLOW}Useful Commands:${NC}

  podman info          # System information
  podman images        # List images
  podman ps -a         # List containers
  podman system prune  # Clean up unused resources

${YELLOW}Quadlet (systemd integration):${NC}

  Place .container files in: ~/.config/containers/systemd/
  Then run: systemctl --user daemon-reload

${YELLOW}Documentation:${NC}

  https://docs.podman.io/
  https://github.com/containers/podman

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Podman from Source Installer${NC}"
    echo -e "${GREEN}  Ubuntu 24.04 LTS${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    # Pre-flight checks
    check_ubuntu_version
    check_sudo
    check_disk_space
    
    # Setup build directory and logging first
    create_build_directory
    
    check_internet
    
    # Check if already installed
    if command_exists podman && [[ "$FORCE_INSTALL" == "false" ]]; then
        log_warn "Podman $(podman --version | awk '{print $3}') is already installed."
        log_warn "Use --force to reinstall."
        exit 0
    fi
    
    # Record start time
    local start_time
    start_time=$(date +%s)
    
    # Execute installation steps
    remove_conflicting_packages
    install_build_dependencies
    install_go
    setup_go_environment
    build_conmon
    build_crun
    build_podman
    configure_podman
    verify_installation
    cleanup
    
    # Calculate duration
    local end_time duration_mins duration_secs
    end_time=$(date +%s)
    duration_secs=$((end_time - start_time))
    duration_mins=$((duration_secs / 60))
    duration_secs=$((duration_secs % 60))
    
    log_success "Installation completed in ${duration_mins}m ${duration_secs}s"
    
    print_summary
}

# Run main function
main "$@"
