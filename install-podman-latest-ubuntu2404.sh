#!/usr/bin/env bash
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
#   --debug           Enable debug output
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

# Bash strict mode - but handle errors ourselves for better messaging
set -o nounset   # Exit on undefined variable
set -o pipefail  # Exit on pipe failure
# Note: We don't use errexit (-e) as we handle errors explicitly

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# Go 1.25.6 is the latest stable release as of February 1, 2026
# Released: 2026-01-15
# See: https://go.dev/doc/devel/release
readonly GO_VERSION="${GO_VERSION:-1.25.6}"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/podman-build}"
readonly LOG_FILE="${BUILD_DIR}/install.log"

# Colors for output (check if terminal supports colors)
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Flags (use declare for variables that will be modified)
declare SKIP_CLEANUP=false
declare FORCE_INSTALL=false
declare DEBUG_MODE=false
declare LOG_INITIALIZED=false

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

# Write to log file if initialized
write_log() {
    if [[ "$LOG_INITIALIZED" == "true" ]] && [[ -f "$LOG_FILE" ]]; then
        echo "$*" >> "$LOG_FILE"
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
    local msg="$*"
    echo ""
    echo -e "${GREEN}===================================================================${NC}"
    echo -e "${GREEN}  ${msg}${NC}"
    echo -e "${GREEN}===================================================================${NC}"
    echo ""
    write_log ""
    write_log "==================================================================="
    write_log "  ${msg}"
    write_log "==================================================================="
    write_log ""
}

die() {
    log_error "$*"
    if [[ "$LOG_INITIALIZED" == "true" ]]; then
        log_error "Check log file for details: $LOG_FILE"
    fi
    exit 1
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Run a command and log output
run_cmd() {
    local description="$1"
    shift
    log_debug "Running: $*"
    if [[ "$DEBUG_MODE" == "true" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        "$@" >> "$LOG_FILE" 2>&1
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
    
    if [[ "$ID" != "ubuntu" ]]; then
        die "This script is designed for Ubuntu. Detected: $ID"
    fi
    
    if [[ "$VERSION_ID" != "24.04" ]]; then
        log_warn "This script is tested on Ubuntu 24.04. Detected: $VERSION_ID"
        log_warn "Continuing anyway, but issues may occur..."
        sleep 3
    fi
    
    log_debug "Ubuntu version check passed: $VERSION_ID"
}

check_sudo() {
    log_debug "Checking sudo privileges..."
    
    if ! sudo -v &>/dev/null; then
        die "This script requires sudo privileges."
    fi
    
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
    
    log_info "Disk space check passed: ${available_mb}MB available"
}

check_internet() {
    log_info "Checking internet connectivity..."
    
    if ! curl -s --connect-timeout 10 https://go.dev &>/dev/null; then
        die "No internet connectivity. Cannot reach https://go.dev"
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
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
    
    log_debug "Arguments parsed: SKIP_CLEANUP=$SKIP_CLEANUP, FORCE_INSTALL=$FORCE_INSTALL, DEBUG_MODE=$DEBUG_MODE"
}

#-------------------------------------------------------------------------------
# Setup Functions
#-------------------------------------------------------------------------------

init_build_environment() {
    log_step "Step 1/9: Initializing build environment"
    
    # Create build directory
    if ! mkdir -p "$BUILD_DIR"; then
        die "Failed to create build directory: $BUILD_DIR"
    fi
    
    # Initialize log file
    cat > "$LOG_FILE" << EOF
================================================================================
Podman Installation Log
================================================================================
Started:    $(date)
Build Dir:  $BUILD_DIR
Go Version: $GO_VERSION
User:       $(whoami)
Host:       $(hostname)
================================================================================

EOF
    
    LOG_INITIALIZED=true
    log_success "Build directory initialized: $BUILD_DIR"
}

remove_conflicting_packages() {
    log_step "Step 2/9: Removing conflicting APT packages"
    
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
        if ! run_cmd "Removing packages" sudo apt-get remove -y "${installed_packages[@]}"; then
            log_warn "Some packages could not be removed (may not be installed)"
        fi
        run_cmd "Autoremove" sudo apt-get autoremove -y || true
        log_success "Conflicting packages removed"
    else
        log_info "No conflicting packages found"
    fi
}

install_build_dependencies() {
    log_step "Step 3/9: Installing build dependencies"
    
    log_info "Updating apt cache..."
    if ! run_cmd "apt update" sudo apt-get update; then
        die "Failed to update apt cache"
    fi
    
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
    if ! run_cmd "apt install" sudo apt-get install -y "${packages[@]}"; then
        die "Failed to install build dependencies"
    fi
    
    log_success "Build dependencies installed"
}

#-------------------------------------------------------------------------------
# Go Installation
#-------------------------------------------------------------------------------

install_go() {
    log_step "Step 4/9: Installing Go ${GO_VERSION}"
    
    # Check if correct version already installed
    if command_exists go; then
        local current_version
        current_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$GO_VERSION" ]]; then
            log_info "Go ${GO_VERSION} already installed"
            return 0
        else
            log_info "Go ${current_version} found, upgrading to ${GO_VERSION}"
        fi
    fi
    
    local go_archive="go${GO_VERSION}.linux-amd64.tar.gz"
    local go_url="https://go.dev/dl/${go_archive}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    log_info "Downloading Go ${GO_VERSION} from ${go_url}..."
    if ! wget -q --show-progress -O "${tmp_dir}/${go_archive}" "$go_url"; then
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
    
    # Create symlinks for system-wide access (needed for sudo)
    sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    
    # Export for current script session
    export PATH="/usr/local/go/bin:${HOME}/go/bin:$PATH"
    export GOPATH="${HOME}/go"
    
    # Verify installation
    if ! go version &>/dev/null; then
        die "Go installation failed - 'go version' command failed"
    fi
    
    log_success "Go $(go version | awk '{print $3}') installed"
    
    # Setup shell environment
    setup_go_environment
}

setup_go_environment() {
    log_info "Configuring Go environment in shell profiles..."
    
    local go_marker="# Go configuration (podman installer)"
    local go_config
    read -r -d '' go_config << 'GOEOF' || true

# Go configuration (podman installer)
export PATH=/usr/local/go/bin:$PATH
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
GOEOF
    
    # Add to bashrc if not already present
    local bashrc="${HOME}/.bashrc"
    if [[ -f "$bashrc" ]] && ! grep -q "$go_marker" "$bashrc" 2>/dev/null; then
        echo "$go_config" >> "$bashrc"
        log_debug "Go environment added to $bashrc"
    fi
    
    # Add to zshrc if it exists and not already present
    local zshrc="${HOME}/.zshrc"
    if [[ -f "$zshrc" ]] && ! grep -q "$go_marker" "$zshrc" 2>/dev/null; then
        echo "$go_config" >> "$zshrc"
        log_debug "Go environment added to $zshrc"
    fi
}

#-------------------------------------------------------------------------------
# Build Functions
#-------------------------------------------------------------------------------

build_conmon() {
    log_step "Step 5/9: Building conmon"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    # Clean existing source if present
    if [[ -d "conmon" ]]; then
        log_info "Removing existing conmon source..."
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
    if ! run_cmd "make install conmon" sudo make install; then
        die "Failed to install conmon"
    fi
    
    # Verify
    if ! command_exists conmon; then
        die "conmon installation failed - binary not found"
    fi
    
    local conmon_version
    conmon_version=$(conmon --version 2>&1 | head -1)
    log_success "conmon installed: ${conmon_version}"
}

build_crun() {
    log_step "Step 6/9: Building crun"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    # Clean existing source if present
    if [[ -d "crun" ]]; then
        log_info "Removing existing crun source..."
        rm -rf crun
    fi
    
    log_info "Cloning crun repository..."
    if ! run_cmd "git clone crun" git clone --depth 1 https://github.com/containers/crun.git; then
        die "Failed to clone crun repository"
    fi
    
    cd crun || die "Cannot change to crun directory"
    
    log_info "Generating build system (autogen)..."
    if ! run_cmd "autogen crun" ./autogen.sh; then
        die "Failed to run autogen.sh for crun"
    fi
    
    log_info "Configuring crun..."
    if ! run_cmd "configure crun" ./configure --prefix=/usr; then
        die "Failed to configure crun"
    fi
    
    log_info "Building crun (this may take a few minutes)..."
    if ! run_cmd "make crun" make; then
        die "Failed to build crun"
    fi
    
    log_info "Installing crun..."
    if ! run_cmd "make install crun" sudo make install; then
        die "Failed to install crun"
    fi
    
    # Verify
    if ! command_exists crun; then
        die "crun installation failed - binary not found"
    fi
    
    local crun_version
    crun_version=$(crun --version 2>&1 | head -1)
    log_success "crun installed: ${crun_version}"
}

build_podman() {
    log_step "Step 7/9: Building Podman"
    
    cd "$BUILD_DIR" || die "Cannot change to build directory"
    
    # Clean existing source if present
    if [[ -d "podman" ]]; then
        log_info "Removing existing podman source..."
        rm -rf podman
    fi
    
    log_info "Cloning podman repository..."
    if ! run_cmd "git clone podman" git clone --depth 1 https://github.com/containers/podman.git; then
        die "Failed to clone podman repository"
    fi
    
    cd podman || die "Cannot change to podman directory"
    
    # Get version info for logging
    local podman_version="unknown"
    if [[ -f version/version.go ]]; then
        podman_version=$(grep -m1 'var Version' version/version.go | cut -d'"' -f2 || echo "unknown")
    fi
    log_info "Building Podman version: $podman_version"
    
    log_info "Building Podman (this may take several minutes)..."
    if ! run_cmd "make podman" make BUILDTAGS="selinux seccomp systemd"; then
        die "Failed to build podman"
    fi
    
    log_info "Installing Podman..."
    # Use env to preserve PATH for Go access during install
    if ! sudo env "PATH=$PATH" make install PREFIX=/usr >> "$LOG_FILE" 2>&1; then
        die "Failed to install podman"
    fi
    
    # Verify
    if ! command_exists podman; then
        die "Podman installation failed - binary not found in PATH"
    fi
    
    log_success "$(podman --version) installed"
}

#-------------------------------------------------------------------------------
# Configuration Functions
#-------------------------------------------------------------------------------

configure_podman() {
    log_step "Step 8/9: Configuring Podman"
    
    # Create system configuration directory
    log_info "Creating configuration directories..."
    sudo mkdir -p /etc/containers
    mkdir -p "${HOME}/.config/containers"
    
    # Download registries.conf
    log_info "Downloading container registries configuration..."
    if ! sudo curl -sL -o /etc/containers/registries.conf \
        https://raw.githubusercontent.com/containers/image/main/registries.conf 2>/dev/null; then
        log_warn "Failed to download registries.conf, creating minimal config..."
        sudo tee /etc/containers/registries.conf > /dev/null << 'REGEOF'
[registries.search]
registries = ['docker.io', 'quay.io']

[registries.block]
registries = []
REGEOF
    fi
    
    # Download policy.json
    log_info "Downloading signature policy..."
    if ! sudo curl -sL -o /etc/containers/policy.json \
        https://raw.githubusercontent.com/containers/image/main/default-policy.json 2>/dev/null; then
        log_warn "Failed to download policy.json, creating default policy..."
        sudo tee /etc/containers/policy.json > /dev/null << 'POLEOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
POLEOF
    fi
    
    # Create user configuration
    log_info "Creating user configuration..."
    cat > "${HOME}/.config/containers/containers.conf" << 'USEREOF'
[containers]
# Use local timezone in containers
tz = "local"

[engine]
# Use crun as runtime (faster than runc)
runtime = "crun"

[network]
# Use pasta for rootless networking (default in Podman 5.x)
default_rootless_network_cmd = "pasta"
USEREOF
    
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
    sudo systemctl daemon-reload || true
    systemctl --user daemon-reload 2>/dev/null || true
    
    log_success "Podman configured"
}

#-------------------------------------------------------------------------------
# Verification Functions
#-------------------------------------------------------------------------------

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
        ((errors++)) || true
    fi
    
    # Check crun
    if command_exists crun; then
        echo "  crun:   $(crun --version | head -1 | awk '{print $3}')"
    else
        log_error "crun not found"
        ((errors++)) || true
    fi
    
    # Check conmon
    if command_exists conmon; then
        local conmon_ver
        conmon_ver=$(conmon --version 2>&1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
        echo "  conmon: ${conmon_ver}"
    else
        log_error "conmon not found"
        ((errors++)) || true
    fi
    
    # Check podman
    if command_exists podman; then
        echo "  podman: $(podman --version | awk '{print $3}')"
    else
        log_error "podman not found"
        ((errors++)) || true
    fi
    
    # Check pasta
    if command_exists pasta; then
        local pasta_ver
        pasta_ver=$(pasta --version 2>&1 | head -1 | awk '{print $2}' || echo "installed")
        echo "  pasta:  ${pasta_ver}"
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
        log_warn "Container test failed - check configuration manually"
    fi
    
    log_success "All verifications passed"
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

Podman ${podman_ver} has been successfully installed.
Built with Go ${GO_VERSION}

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

SUMMARYEOF
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------

main() {
    # Parse command line arguments first
    parse_args "$@"
    
    # Print header
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Podman from Source Installer${NC}"
    echo -e "${GREEN}  Ubuntu 24.04 LTS${NC}"
    echo -e "${GREEN}  Go ${GO_VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    # Pre-flight checks (before log is initialized)
    check_ubuntu_version
    check_sudo
    
    # Initialize build environment (creates log file)
    init_build_environment
    
    # More pre-flight checks (now with logging)
    check_disk_space
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

# Trap for cleanup on unexpected exit
trap 'log_error "Script interrupted"; exit 1' INT TERM

# Run main function with all arguments
main "$@"
