# Building and Installing Latest Podman on Ubuntu 24.04 LTS

This guide documents a clean, from-source installation of Podman 5.x/6.x on Ubuntu 24.04 LTS (Noble Numbat). Ubuntu 24.04 ships with Podman 4.9.3 and outdated dependencies that are incompatible with modern Podman releases.

## Prerequisites

- Ubuntu 24.04 LTS (server or desktop)
- sudo privileges
- ~2GB free disk space for builds
- Internet connectivity

## Overview

Ubuntu 24.04's package versions are too old for Podman 5.x+:
- **Go**: Ubuntu ships 1.22.x; Podman requires 1.23.x+
- **crun**: Ubuntu ships 1.14.x; Podman 5.x+ requires newer versions
- **conmon**: Should be built from source for compatibility

We'll build these components from source in order:
1. Go (install from official tarball)
2. conmon (container monitor)
3. crun (OCI runtime)
4. Podman

---

## Step 1: Remove Conflicting APT Packages

Remove any existing container tooling to avoid version conflicts:

```bash
sudo apt remove -y podman crun conmon buildah skopeo containers-common
sudo apt autoremove -y
```

Verify removal:

```bash
which podman crun conmon  # Should return nothing or "not found"
```

---

## Step 2: Install Build Dependencies

### Core build tools

```bash
sudo apt update
sudo apt install -y \
    make \
    gcc \
    pkg-config \
    git \
    curl \
    wget
```

### Podman build dependencies

```bash
sudo apt install -y \
    btrfs-progs \
    libbtrfs-dev \
    libseccomp-dev \
    libassuan-dev \
    libgpgme-dev \
    libdevmapper-dev \
    libglib2.0-dev \
    libostree-dev \
    libprotobuf-dev \
    libprotobuf-c-dev \
    libsystemd-dev \
    uidmap \
    go-md2man
```

### crun build dependencies

```bash
sudo apt install -y \
    autoconf \
    automake \
    libtool \
    libcap-dev \
    libyajl-dev \
    python3
```

### Runtime dependencies

```bash
sudo apt install -y \
    passt \
    fuse-overlayfs \
    slirp4netns \
    iptables
```

---

## Step 3: Install Modern Go

Ubuntu 24.04's Go is too old. Install Go 1.25.6 (latest stable as of February 2026) from the official tarball.

**Go 1.25.6** was released on January 15, 2026 and includes security fixes to the go command, archive/zip, crypto/tls, and net/url packages.

```bash
GO_VERSION="1.25.6"  # Latest stable as of Feb 1, 2026

# Download
cd /tmp
wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"

# Remove any existing Go installation
sudo rm -rf /usr/local/go

# Extract to /usr/local
sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"

# Cleanup
rm "go${GO_VERSION}.linux-amd64.tar.gz"
```

### Configure Go environment

Add to your shell profile (`~/.bashrc` or `~/.zshrc`):

```bash
cat >> ~/.bashrc << 'EOF'

# Go configuration
export PATH=/usr/local/go/bin:$PATH
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
EOF

# Load immediately
source ~/.bashrc
```

### Create system-wide symlinks (for sudo access)

```bash
sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
```

### Verify Go installation

```bash
go version  # Should show go1.25.6
```

---

## Step 4: Create Build Directory

```bash
mkdir -p ~/prjs/containers
cd ~/prjs/containers
```

---

## Step 5: Build and Install conmon

conmon (container monitor) monitors OCI containers and handles logging.

```bash
cd ~/prjs/containers

# Clone repository
git clone https://github.com/containers/conmon.git
cd conmon

# Build
make

# Install
sudo make install

# Verify
conmon --version
```

---

## Step 6: Build and Install crun

crun is the OCI runtime that spawns and runs containers.

```bash
cd ~/prjs/containers

# Clone repository
git clone https://github.com/containers/crun.git
cd crun

# Generate build system
./autogen.sh

# Configure with /usr prefix to match system paths
./configure --prefix=/usr

# Build
make

# Install
sudo make install

# Verify
crun --version
```

Expected output:
```
crun version 1.x.x
...
```

---

## Step 7: Build and Install Podman

```bash
cd ~/prjs/containers

# Clone repository
git clone https://github.com/containers/podman.git
cd podman

# Checkout latest stable release (optional - main branch is usually fine)
# git checkout v5.4.0

# Build with recommended features
make BUILDTAGS="selinux seccomp systemd"
```

### Install Podman

Use `env` to preserve PATH for sudo:

```bash
sudo env "PATH=$PATH" make install PREFIX=/usr
```

### Verify installation

```bash
podman --version
```

---

## Step 8: Configure Podman

### Create configuration directories

```bash
sudo mkdir -p /etc/containers
mkdir -p ~/.config/containers
```

### Download container registries configuration

```bash
sudo curl -L -o /etc/containers/registries.conf \
    https://raw.githubusercontent.com/containers/image/main/registries.conf
```

### Download image signature policy

```bash
sudo curl -L -o /etc/containers/policy.json \
    https://raw.githubusercontent.com/containers/image/main/default-policy.json
```

### (Optional) User-level configuration

Create user config for rootless preferences:

```bash
cat > ~/.config/containers/containers.conf << 'EOF'
[containers]
# Set default timezone in containers
tz = "local"

[engine]
# Use crun as runtime (faster than runc)
runtime = "crun"

[network]
# Use pasta for rootless networking (default in Podman 5.x)
default_rootless_network_cmd = "pasta"
EOF
```

---

## Step 9: Enable Rootless Support

Ensure subuid/subgid mappings exist for your user:

```bash
# Check if mappings exist
grep $USER /etc/subuid /etc/subgid

# If not present, add them (100000 subordinate UIDs/GIDs starting at 100000)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

---

## Step 10: Enable Systemd Services (Optional)

For auto-update and socket activation:

```bash
# System-wide services
sudo systemctl daemon-reload
sudo systemctl enable --now podman.socket

# User services (rootless)
systemctl --user daemon-reload
systemctl --user enable --now podman.socket
```

---

## Step 11: Verification

### Check versions

```bash
echo "=== Versions ==="
go version
crun --version | head -1
conmon --version
podman --version
```

### Check Podman info

```bash
podman info
```

### Test rootless container

```bash
podman run --rm docker.io/library/alpine echo "Hello from Podman $(podman --version)"
```

### Test with systemd integration

```bash
podman run -d --name test-nginx -p 8080:80 docker.io/library/nginx:alpine
curl -s http://localhost:8080 | head -5
podman stop test-nginx
podman rm test-nginx
```

---

## Troubleshooting

### "pasta" not found

```bash
sudo apt install -y passt
```

### "crun: unknown version specified"

Your crun is too old. Rebuild from source per Step 6.

### Permission denied errors in rootless mode

```bash
# Ensure subuid/subgid are configured
grep $USER /etc/subuid /etc/subgid

# Reset podman storage if corrupted
podman system reset
```

### "go: command not found" during sudo make install

Use the env wrapper:
```bash
sudo env "PATH=$PATH" make install PREFIX=/usr
```

### Missing btrfs/version.h

```bash
sudo apt install -y libbtrfs-dev
```

### go-md2man not found during conmon install

```bash
sudo apt install -y go-md2man
```

---

## Uninstallation

If you need to revert to Ubuntu packages or clean up:

```bash
# Remove source-built binaries
sudo rm -f /usr/bin/podman /usr/bin/podman-remote
sudo rm -f /usr/bin/crun
sudo rm -f /usr/local/bin/conmon
sudo rm -rf /usr/libexec/podman
sudo rm -rf /usr/share/man/man1/podman*
sudo rm -rf /usr/lib/systemd/system/podman*
sudo rm -rf /usr/lib/systemd/user/podman*

# Remove configurations (optional - keeps your settings)
# sudo rm -rf /etc/containers

# Remove user data (optional - destroys all containers/images)
# podman system reset --force
# rm -rf ~/.local/share/containers
# rm -rf ~/.config/containers

# Reinstall from apt if desired
sudo apt install podman
```

---

## Quick Reference: Automated Installation Script

An automated installation script `install-podman-latest.sh` is provided that performs all steps in this guide.

### Usage

```bash
# Download or create the script, then:
chmod +x install-podman-latest.sh
./install-podman-latest.sh
```

### Script Options

| Option | Description |
|--------|-------------|
| `--force` | Reinstall even if Podman is already installed |
| `--skip-cleanup` | Keep build directories for debugging |
| `--help` | Show help message |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GO_VERSION` | 1.25.6 | Go version to install |
| `BUILD_DIR` | ./podman-build | Directory for build files |

### Examples

```bash
# Standard installation
./install-podman-latest.sh

# Force reinstall
./install-podman-latest.sh --force

# Use different Go version
GO_VERSION=1.25.7 ./install-podman-latest.sh

# Keep build files for inspection
./install-podman-latest.sh --skip-cleanup
```

---

## Version History

| Component | Ubuntu 24.04 APT | This Guide |
|-----------|------------------|------------|
| Go | 1.22.x | **1.25.6** |
| Podman | 4.9.3 | **latest (main)** |
| crun | 1.14.x | **latest (main)** |
| conmon | varies | **latest (main)** |

---

## References

- [Go Downloads](https://go.dev/dl/)
- [Go Release History](https://go.dev/doc/devel/release) - Go 1.25.6 released 2026-01-15
- [Podman Installation Docs](https://podman.io/docs/installation)
- [Podman GitHub](https://github.com/containers/podman)
- [crun GitHub](https://github.com/containers/crun)
- [conmon GitHub](https://github.com/containers/conmon)

---

*Guide created: February 2026*  
*Tested on: Ubuntu 24.04.1 LTS*  
*Go version: 1.25.6 (released 2026-01-15)*  
*Podman version: 6.x (main branch)*
