#!/bin/bash
set -o pipefail

# install.sh - prepares a Linux cloning host for CycCloner2000.

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run as root: sudo $0"
    exit 1
fi

INSTALL_PACKAGES=true
if [ "${1:-}" = "--no-packages" ]; then
    INSTALL_PACKAGES=false
fi

STAMP=$(date +%Y%m%d)
LIMITS_BEGIN="# BEGIN CycCloner2000 limits"
LIMITS_END="# END CycCloner2000 limits"
SYSCTL_BEGIN="# BEGIN CycCloner2000 sysctl"
SYSCTL_END="# END CycCloner2000 sysctl"

replace_block() {
    local file=$1
    local begin=$2
    local end=$3
    local content=$4

    touch "$file"

    if grep -q "$begin" "$file"; then
        sed -i "/$begin/,/$end/d" "$file"
    fi

    {
        echo ""
        echo "$begin"
        printf '%s\n' "$content"
        echo "$end"
    } >> "$file"
}

install_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[WARN] apt-get not found; skipping package installation"
        return 0
    fi

    echo "[1/6] Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        parted \
        partclone \
        pigz \
        gdisk \
        util-linux \
        ntfs-3g \
        grub2-common \
        grub-efi-amd64-bin \
        grub-pc-bin \
        os-prober
}

echo "=== CycCloner2000 installer ==="

if [ "$INSTALL_PACKAGES" = "true" ]; then
    install_packages
else
    echo "[1/6] Skipping package installation"
fi

echo "[2/6] Creating config backups..."
cp -n /etc/security/limits.conf "/etc/security/limits.conf.backup.$STAMP" 2>/dev/null || true
cp -n /etc/systemd/logind.conf "/etc/systemd/logind.conf.backup.$STAMP" 2>/dev/null || true
cp -n /etc/sysctl.conf "/etc/sysctl.conf.backup.$STAMP" 2>/dev/null || true

echo "[3/6] Configuring /etc/security/limits.conf..."
replace_block /etc/security/limits.conf "$LIMITS_BEGIN" "$LIMITS_END" "*    soft    nproc     8192
*    hard    nproc     16384
*    soft    nofile    8192
*    hard    nofile    16384
root soft    nproc     unlimited
root hard    nproc     unlimited
root soft    nofile    unlimited
root hard    nofile    unlimited"

echo "[4/6] Configuring /etc/systemd/logind.conf..."
touch /etc/systemd/logind.conf
if grep -q '^#*UserTasksMax=' /etc/systemd/logind.conf; then
    sed -i 's/^#*UserTasksMax=.*/UserTasksMax=16384/' /etc/systemd/logind.conf
else
    echo "UserTasksMax=16384" >> /etc/systemd/logind.conf
fi

echo "[5/6] Configuring /etc/sysctl.conf..."
replace_block /etc/sysctl.conf "$SYSCTL_BEGIN" "$SYSCTL_END" "kernel.pid_max = 65536
kernel.threads-max = 65536
vm.max_map_count = 262144"

echo "[6/6] Applying runtime settings..."
sysctl -p
systemctl restart systemd-logind 2>/dev/null || echo "[WARN] Could not restart systemd-logind"

echo ""
echo "=== DONE ==="
echo "Packages installed: $INSTALL_PACKAGES"
echo "Backups: *.backup.$STAMP"
echo "Log out and log in again, or reboot, so session limits take effect."
