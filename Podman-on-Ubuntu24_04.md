# Building and Installing Latest Podman on Ubuntu 24.04 LTS

This guide documents a complete, from-source installation of Podman 5.x/6.x on Ubuntu 24.04 LTS (Noble Numbat). Ubuntu 24.04 ships with Podman 4.9.3 and outdated dependencies incompatible with modern Podman releases.

## Quick Start (Automated)

```bash
chmod +x install-podman-latest.sh
./install-podman-latest.sh
```

For manual installation, follow the detailed steps below.

---

## Table of Contents

1. [Why Build from Source?](#why-build-from-source)
2. [Prerequisites](#prerequisites)
3. [Step 1: Remove Conflicting Packages](#step-1-remove-conflicting-packages)
4. [Step 2: Install Dependencies](#step-2-install-dependencies)
5. [Step 3: Install Modern Go](#step-3-install-modern-go)
6. [Step 4: Build conmon](#step-4-build-conmon)
7. [Step 5: Build crun](#step-5-build-crun)
8. [Step 6: Build Podman](#step-6-build-podman)
9. [Step 7: Configure Podman](#step-7-configure-podman)
10. [Step 8: Validate Installation](#step-8-validate-installation)
11. [Troubleshooting](#troubleshooting)
12. [Uninstallation](#uninstallation)

---

## Why Build from Source?

Ubuntu 24.04's package versions are too old for Podman 5.x+:

| Component | Ubuntu 24.04 APT | Required | This Guide |
|-----------|------------------|----------|------------|
| Go | 1.22.x | 1.23.x+ | **1.25.6** |
| Podman | 4.9.3 | 5.x/6.x | **latest** |
| crun | 1.14.x | latest | **latest** |
| conmon | varies | latest | **latest** |
| netavark | 1.4.0 | 1.4.0+ | **1.4.0 (apt)** |
| aardvark-dns | 1.4.0 | 1.4.0+ | **1.4.0 (apt)** |

**Built from source:** Go, conmon, crun, Podman

**Kept from apt (work fine):** netavark, aardvark-dns, passt, containernetworking-plugins

---

## Prerequisites

- Ubuntu 24.04 LTS (server or desktop)
- sudo privileges
- ~2GB free disk space
- Internet connectivity

---

## Step 1: Remove Conflicting Packages

Remove only packages we're building from source. Keep runtime dependencies.

```bash
sudo apt remove -y podman crun conmon buildah skopeo containers-common
sudo apt autoremove -y
```

Verify:

```bash
which podman crun conmon  # Should return nothing
```

---

## Step 2: Install Dependencies

### Build tools

```bash
sudo apt update
sudo apt install -y \
    make gcc pkg-config git curl wget
```

### Podman build dependencies

```bash
sudo apt install -y \
    btrfs-progs libbtrfs-dev libseccomp-dev libassuan-dev \
    libgpgme-dev libdevmapper-dev libglib2.0-dev libostree-dev \
    libprotobuf-dev libprotobuf-c-dev libsystemd-dev uidmap go-md2man
```

### crun build dependencies

```bash
sudo apt install -y \
    autoconf automake libtool libcap-dev libyajl-dev python3
```

### Runtime dependencies (CRITICAL)

These are **essential** for Podman networking. Missing these causes:
- `Error: could not find "netavark"`
- Container networking failures

```bash
sudo apt install -y \
    netavark \
    aardvark-dns \
    containernetworking-plugins \
    passt \
    slirp4netns \
    fuse-overlayfs \
    iptables \
    libsubid4
```

### Verify critical components

```bash
# netavark (network backend)
ls -la /usr/lib/podman/netavark

# aardvark-dns (container DNS)
ls -la /usr/lib/podman/aardvark-dns

# pasta (rootless networking)
which pasta
```

---

## Step 3: Install Modern Go

Go **1.25.6** (released January 15, 2026) is the latest stable version.

```bash
GO_VERSION="1.25.6"

# Download
cd /tmp
wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"

# Install
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
rm "go${GO_VERSION}.linux-amd64.tar.gz"

# System-wide symlinks (for sudo access)
sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
```

### Add to shell profile

Add to `~/.bashrc` or `~/.zshrc`:

```bash
cat >> ~/.bashrc << 'EOF'

# Go configuration
export PATH=/usr/local/go/bin:$PATH
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
EOF

source ~/.bashrc
```

### Verify

```bash
go version  # Should show go1.25.6
```

---

## Step 4: Build conmon

conmon (container monitor) handles container logging and lifecycle.

```bash
mkdir -p ~/prjs/containers && cd ~/prjs/containers

git clone --depth 1 https://github.com/containers/conmon.git
cd conmon

make
sudo make install

# Verify
conmon --version
```

---

## Step 5: Build crun

crun is the OCI runtime (faster than runc).

```bash
cd ~/prjs/containers

git clone --depth 1 https://github.com/containers/crun.git
cd crun

./autogen.sh
./configure --prefix=/usr
make
sudo make install

# Verify
crun --version
```

---

## Step 6: Build Podman

```bash
cd ~/prjs/containers

git clone --depth 1 https://github.com/containers/podman.git
cd podman

make BUILDTAGS="selinux seccomp systemd"

# Use env to preserve PATH for Go during install
sudo env "PATH=$PATH" make install PREFIX=/usr

# Verify
podman --version
```

---

## Step 7: Configure Podman

### Create directories

```bash
sudo mkdir -p /etc/containers
mkdir -p ~/.config/containers
```

### Download system configs

```bash
# Registries
sudo curl -L -o /etc/containers/registries.conf \
    https://raw.githubusercontent.com/containers/image/main/registries.conf

# Image policy
sudo curl -L -o /etc/containers/policy.json \
    https://raw.githubusercontent.com/containers/image/main/default-policy.json
```

### Create user configuration

**IMPORTANT:** Always create this file fresh (don't append) to avoid duplicate section errors.

```bash
cat > ~/.config/containers/containers.conf << 'EOF'
# Podman user configuration

[containers]
tz = "local"
default_ulimits = ["nofile=65536:65536"]

[engine]
runtime = "crun"
helper_binaries_dir = [
  "/usr/lib/podman",
  "/usr/libexec/podman",
  "/usr/local/lib/podman",
  "/usr/local/libexec/podman"
]
database_backend = "sqlite"
events_logger = "journald"

[network]
network_backend = "netavark"
default_rootless_network_cmd = "pasta"
firewall_driver = "iptables"
EOF
```

### Enable rootless containers

```bash
# Check existing mappings
grep $USER /etc/subuid /etc/subgid

# Add if missing
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

### Reload systemd

```bash
sudo systemctl daemon-reload
systemctl --user daemon-reload
```

---

## Step 8: Validate Installation

### Check component versions

```bash
echo "=== Component Versions ==="
go version
crun --version | head -1
conmon --version
podman --version
/usr/lib/podman/netavark --version
/usr/lib/podman/aardvark-dns --version
pasta --version
```

### Verify configuration

```bash
podman info
```

Expected output should include:
- `networkBackend: netavark`
- `ociRuntime: name: crun`
- `rootless: true`

### Test container execution

```bash
# Basic test
podman run --rm docker.io/library/alpine echo "Hello from Podman!"

# Network test
podman run --rm alpine ping -c 1 8.8.8.8

# DNS test
podman run --rm alpine nslookup google.com
```

### Test container-to-container networking

```bash
# Create a pod
podman pod create --name testpod

# Run a web server
podman run -d --pod testpod --name web alpine \
    sh -c "echo 'Hello' > /tmp/index.html && httpd -f -p 8080 -h /tmp"

# Test from another container
podman run --rm --pod testpod alpine wget -qO- http://localhost:8080

# Cleanup
podman pod rm -f testpod
```

---

## Troubleshooting

### Error: could not find "netavark"

**Cause:** Network backend binaries not installed or not in helper_binaries_dir.

**Fix:**

```bash
# Install from apt
sudo apt install -y netavark aardvark-dns containernetworking-plugins

# Verify location
ls -la /usr/lib/podman/

# Ensure config has correct paths
cat ~/.config/containers/containers.conf | grep helper_binaries_dir
```

### Error: Key 'engine' has already been defined

**Cause:** Duplicate sections in containers.conf from appending instead of overwriting.

**Fix:**

```bash
# Remove and recreate the config file
rm ~/.config/containers/containers.conf
# Then follow Step 7 to create a fresh config
```

### crun: unknown version specified

**Cause:** Ubuntu's apt crun is too old.

**Fix:** Build crun from source (Step 5).

### Permission denied in rootless mode

**Fix:**

```bash
# Add subuid/subgid mappings
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER

# Reset storage if corrupted
podman system reset
```

### go: command not found during sudo make install

**Cause:** sudo doesn't inherit your PATH.

**Fix:**

```bash
sudo env "PATH=$PATH" make install PREFIX=/usr
```

### Missing btrfs/version.h

**Fix:**

```bash
sudo apt install -y libbtrfs-dev
```

### go-md2man not found

**Fix:**

```bash
sudo apt install -y go-md2man
```

### Container DNS not resolving

**Fix:**

```bash
# Verify aardvark-dns exists
ls -la /usr/lib/podman/aardvark-dns

# Check network config
podman network inspect podman | grep dns_enabled
```

### pasta not found (rootless networking fails)

**Fix:**

```bash
sudo apt install -y passt
```

---

## Uninstallation

To remove source-built components:

```bash
# Remove binaries
sudo rm -f /usr/bin/podman /usr/bin/podman-remote
sudo rm -f /usr/bin/crun
sudo rm -f /usr/local/bin/conmon
sudo rm -rf /usr/libexec/podman
sudo rm -rf /usr/share/man/man1/podman*
sudo rm -rf /usr/lib/systemd/system/podman*
sudo rm -rf /usr/lib/systemd/user/podman*

# Remove configs (optional)
# sudo rm -rf /etc/containers

# Remove user data (WARNING: destroys all containers/images)
# podman system reset --force
# rm -rf ~/.local/share/containers
# rm -rf ~/.config/containers

# Reinstall from apt if desired
sudo apt install podman
```

---

## Automated Installation Script

### Usage

```bash
chmod +x install-podman-latest.sh
./install-podman-latest.sh
```

### Options

| Option | Description |
|--------|-------------|
| `--force` | Reinstall even if Podman exists |
| `--skip-cleanup` | Keep build directories |
| `--debug` | Verbose output |
| `--help` | Show help |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GO_VERSION` | 1.25.6 | Go version |
| `BUILD_DIR` | ./podman-build | Build directory |

### What the Script Does

1. **Pre-flight checks**: Ubuntu version, architecture, sudo, disk space, internet
2. **Remove conflicts**: Removes apt packages we're building from source
3. **Install dependencies**: All build and runtime deps including netavark, aardvark-dns
4. **Install Go 1.25.6**: From official tarball
5. **Build conmon**: Container monitor
6. **Build crun**: OCI runtime
7. **Build Podman**: With selinux, seccomp, systemd support
8. **Configure**: registries.conf, policy.json, containers.conf, subuid/subgid
9. **Validate**: Component versions, configuration, network backend
10. **Test**: Runs actual containers to verify everything works

### Examples

```bash
# Standard install
./install-podman-latest.sh

# Force reinstall with debug
./install-podman-latest.sh --force --debug

# Different Go version
GO_VERSION=1.25.7 ./install-podman-latest.sh

# Keep build files
./install-podman-latest.sh --skip-cleanup
```

---

## Quick Fix for Existing Systems

If you already have Podman installed but networking isn't working:

```bash
# Install missing network components
sudo apt install -y netavark aardvark-dns containernetworking-plugins

# Create/overwrite user config (don't append!)
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf << 'EOF'
[containers]
tz = "local"

[engine]
runtime = "crun"
helper_binaries_dir = ["/usr/lib/podman", "/usr/libexec/podman", "/usr/local/lib/podman"]

[network]
network_backend = "netavark"
default_rootless_network_cmd = "pasta"
EOF

# Verify
podman info | grep -E "(networkBackend|ociRuntime)"
podman run --rm alpine echo "Success!"
```

---

## References

- [Go Downloads](https://go.dev/dl/)
- [Go 1.25.6 Release Notes](https://go.dev/doc/devel/release) (2026-01-15)
- [Podman Documentation](https://docs.podman.io/)
- [Podman GitHub](https://github.com/containers/podman)
- [crun GitHub](https://github.com/containers/crun)
- [conmon GitHub](https://github.com/containers/conmon)
- [netavark GitHub](https://github.com/containers/netavark)

---

*Version: 2.1.0*  
*Updated: February 2026*  
*Tested: Ubuntu 24.04.1 LTS*
