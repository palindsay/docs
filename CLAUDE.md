# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a system administration project providing installation documentation and automation for building **Podman** from source on **Ubuntu 24.04 LTS** and Ubuntu 24.04-based distributions (Pop!_OS, Linux Mint, etc.). The project exists because Ubuntu 24.04's APT repositories ship outdated components (Go 1.22, Podman 4.9.3) that are incompatible with modern Podman 5.x/6.x.

## Key Files

- `install-podman-latest-ubuntu2404.sh` - Automated installation script (1100+ lines of Bash)
- `Podman-on-Ubuntu24_04.md` - Comprehensive manual installation guide with troubleshooting

## Script Architecture

The installation script follows a 10-step pipeline:

1. **Pre-flight checks** - Ubuntu/derivative version, architecture (x86_64), sudo, disk space (2GB), internet
2. **Cleanup** - Remove conflicting APT packages (podman, buildah, skopeo, golang-go, crun, conmon)
3. **Dependencies** - Install build tools, runtime dependencies, and podman machine components via APT
4. **Go installation** - Download and install Go 1.25.6 from official tarball
5. **Build conmon** - Container monitor from GitHub source
6. **Build crun** - OCI runtime with `--prefix=/usr`
7. **Build Podman** - With tags: `selinux seccomp systemd`
8. **Configuration** - Set up `/etc/containers/` and user configs, subuid/subgid mappings
9. **Validation** - Component versions, network backend (netavark), OCI runtime (crun), machine components
10. **Testing** - Container execution tests (basic, network, DNS)

### Script Options

```bash
./install-podman-latest-ubuntu2404.sh [OPTIONS]
  --skip-cleanup    Preserve build directories for troubleshooting
  --force           Reinstall even if Podman already exists
  --debug           Verbose output with detailed logging
  --help            Display help text

# Environment variables
GO_VERSION=1.25.6   # Go version to install (default)
BUILD_DIR=./podman-build  # Build directory location
```

### Logging Functions

The script uses color-coded logging: `log_debug`, `log_info`, `log_ok`, `log_warn`, `log_error`

## Testing Changes

To test the installation script on a fresh Ubuntu 24.04 system:

```bash
# Basic installation
sudo ./install-podman-latest-ubuntu2404.sh

# Debug mode for troubleshooting
sudo ./install-podman-latest-ubuntu2404.sh --debug

# Force reinstall
sudo ./install-podman-latest-ubuntu2404.sh --force
```

## Critical Dependencies

The script manages these key runtime components that must be installed via APT (not built from source):
- `netavark` - Network backend
- `aardvark-dns` - DNS plugin
- `containernetworking-plugins` - CNI plugins
- `passt` / `slirp4netns` - Rootless networking
- `fuse-overlayfs` - Rootless storage driver
- `libsubid4` - UID/GID mapping support

### Podman Machine Dependencies

For `podman machine init` and `podman machine start` support:
- `qemu-system-x86` - QEMU hypervisor
- `qemu-utils` - Image utilities (qemu-img)
- `ovmf` - UEFI firmware for VMs
- `gvproxy` - VM networking (gvisor-tap-vsock)
- `virtiofsd` - Shared filesystem between host and VM

**Note:** Ubuntu installs gvproxy to `/usr/bin/`, but Podman expects it in `/usr/lib/podman/`. The script creates symlinks automatically.
