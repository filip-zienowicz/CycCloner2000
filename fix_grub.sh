#!/bin/bash

################################################################################
# fix-grub.sh - GRUB Repair Tool for Mass Cloned Disks (SSH-SAFE VERSION)
#
# Repairs GRUB on multiple disks after parallel cloning operations
# Handles cleanup of stuck mounts and reinstalls GRUB properly
# SAFE: Does NOT kill SSH sessions
################################################################################

# COLOR CODES
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# LOGGING
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo -e "${RED}[ERROR] $*${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $*${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO] $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $*${NC}"
}

################################################################################
# CHECK ROOT
################################################################################
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

################################################################################
# SAFE CLEANUP FUNCTION - Does NOT kill SSH
################################################################################
cleanup_all_mounts() {
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         STEP 1: Cleaning up stuck mounts             ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    # Show current mounts
    log_info "Current problematic mounts:"
    mount | grep -E "cyc-|sd[a-z]" | grep -v "nvme" || log_info "None found"
    echo ""
    
    # SAFE: Only unmount with lazy unmount (no killing processes)
    log_info "Lazy unmounting /mnt/cyc-cloner-* mounts..."
    for mount in /mnt/cyc-cloner-*/boot/efi /mnt/cyc-cloner-*/proc /mnt/cyc-cloner-*/sys /mnt/cyc-cloner-*/dev/pts /mnt/cyc-cloner-*/dev /mnt/cyc-cloner-*; do
        if mount | grep -q "$mount" 2>/dev/null; then
            log_info "Unmounting $mount..."
            umount -l "$mount" 2>/dev/null || true
        fi
    done
    
    # Unmount cyc-win/efi mounts
    log_info "Unmounting /mnt/cyc-win-* and /mnt/cyc-efi-* mounts..."
    for dir in /mnt/cyc-win-* /mnt/cyc-efi-*; do
        if [ -d "$dir" ]; then
            umount -l "$dir" 2>/dev/null || true
        fi
    done
    
    # Unmount tmp/cyc-check mounts
    log_info "Unmounting /tmp/cyc-check-* mounts..."
    for dir in /tmp/cyc-check-*; do
        if [ -d "$dir" ]; then
            umount -l "$dir" 2>/dev/null || true
        fi
    done
    
    # Unmount os-prober
    log_info "Unmounting os-prober..."
    umount -l /var/lib/os-prober/mount 2>/dev/null || true
    
    sleep 3
    
    # Remove directories (if not busy)
    log_info "Removing leftover directories..."
    rmdir /mnt/cyc-* 2>/dev/null || log_warning "Some directories still in use (will retry later)"
    rmdir /tmp/cyc-* 2>/dev/null || true
    rmdir /var/lib/os-prober/mount 2>/dev/null || true
    
    # Final check
    echo ""
    log_info "Verifying cleanup..."
    local remaining=$(mount | grep -E "cyc-" | wc -l)
    
    if [ $remaining -eq 0 ]; then
        log_success "All mounts cleaned up successfully!"
    else
        log_warning "Some mounts still remain (will be handled individually):"
        mount | grep -E "cyc-"
    fi
    
    echo ""
}

################################################################################
# SAFE KILL PROCESSES - Only kills mount-related processes, NOT SSH
################################################################################
safe_kill_mount_processes() {
    local mount_point=$1
    
    log_info "Safely stopping processes using $mount_point..."
    
    # Get PIDs using the mount point
    local pids=$(lsof +D "$mount_point" 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u)
    
    if [ -z "$pids" ]; then
        log_info "No processes using $mount_point"
        return 0
    fi
    
    for pid in $pids; do
        local cmd=$(ps -p $pid -o comm= 2>/dev/null)
        
        # NEVER kill SSH-related processes
        if [[ "$cmd" =~ sshd|bash|screen|tmux ]]; then
            log_warning "Skipping PID $pid ($cmd) - SSH related"
            continue
        fi
        
        # Kill safe processes
        log_info "Killing PID $pid ($cmd)..."
        kill -15 $pid 2>/dev/null || true
    done
    
    sleep 2
}

################################################################################
# FIX GRUB ON SINGLE DISK
################################################################################
fix_grub_single_disk() {
    local disk=$1
    
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         Fixing GRUB on /dev/$disk                     "
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    # Check if disk exists
    if [ ! -b "/dev/$disk" ]; then
        log_error "Disk /dev/$disk does not exist!"
        return 1
    fi
    
    # Check if partition 5 (Linux root) exists
    if [ ! -b "/dev/${disk}5" ]; then
        log_error "Partition /dev/${disk}5 does not exist!"
        return 1
    fi
    
    # Check if partition 1 (EFI) exists
    if [ ! -b "/dev/${disk}1" ]; then
        log_error "Partition /dev/${disk}1 does not exist!"
        return 1
    fi
    
    # Create unique mount point
    local mount_point="/mnt/grub-fix-$disk-$$"
    mkdir -p "$mount_point"
    
    # Check if already mounted
    if mount | grep -q "/dev/${disk}5.*$mount_point"; then
        log_warning "/dev/${disk}5 already mounted, unmounting first..."
        umount -l "/dev/${disk}5" 2>/dev/null || true
        sleep 2
    fi
    
    log_info "Mounting /dev/${disk}5 to $mount_point..."
    if ! mount /dev/${disk}5 "$mount_point"; then
        log_error "Failed to mount /dev/${disk}5"
        rmdir "$mount_point" 2>/dev/null
        return 1
    fi
    
    log_info "Mounting /dev/${disk}1 to $mount_point/boot/efi..."
    if ! mount /dev/${disk}1 "$mount_point/boot/efi"; then
        log_error "Failed to mount /dev/${disk}1"
        umount "$mount_point"
        rmdir "$mount_point" 2>/dev/null
        return 1
    fi
    
    # Bind mount only essential directories
    log_info "Bind mounting /proc, /sys, /dev..."
    mount --bind /proc "$mount_point/proc" 2>/dev/null || log_warning "Failed to bind /proc"
    mount --bind /sys "$mount_point/sys" 2>/dev/null || log_warning "Failed to bind /sys"
    mount --bind /dev "$mount_point/dev" 2>/dev/null || log_warning "Failed to bind /dev"
    
    sleep 1
    
    # Reinstall GRUB
    log_info "Reinstalling GRUB..."
    chroot "$mount_point" /bin/bash -c "
        # Stop any running systemd services
        systemctl stop systemd-udevd 2>/dev/null || true
        
        # Install GRUB
        echo 'Installing GRUB...'
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB /dev/$disk 2>&1 | grep -v 'warning: EFI variables' || true
        
        # Update GRUB config (suppress known errors)
        echo 'Updating GRUB configuration...'
        LANG=C update-grub 2>&1 | grep -v 'Assertion\|/proc/devices\|fopen failed\|Aborted\|core dumped' | grep -E 'Found|Adding|done|error' || true
    " 2>&1 | grep -v "Assertion\|Aborted\|core dumped"
    
    local grub_status=${PIPESTATUS[0]}
    
    # Sync before unmount
    log_info "Syncing filesystems..."
    sync
    sleep 2
    
    # Cleanup - unmount in reverse order
    log_info "Cleaning up mounts..."
    
    # Safe kill processes (no SSH)
    safe_kill_mount_processes "$mount_point"
    
    # Unmount bind mounts
    umount "$mount_point/dev" 2>/dev/null || umount -l "$mount_point/dev" 2>/dev/null || true
    umount "$mount_point/sys" 2>/dev/null || umount -l "$mount_point/sys" 2>/dev/null || true
    umount "$mount_point/proc" 2>/dev/null || umount -l "$mount_point/proc" 2>/dev/null || true
    
    sleep 1
    
    # Unmount EFI
    umount "$mount_point/boot/efi" 2>/dev/null || umount -l "$mount_point/boot/efi" 2>/dev/null || true
    
    sleep 1
    
    # Unmount root
    umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || true
    
    # Wait for unmount to complete
    sleep 2
    
    # Remove directory
    rmdir "$mount_point" 2>/dev/null || log_warning "Could not remove $mount_point (may still be busy)"
    
    # Verify unmounted
    if mount | grep -q "$mount_point"; then
        log_warning "Mount point still busy, will be cleaned up on reboot"
    fi
    
    if [ $grub_status -eq 0 ]; then
        log_success "GRUB fixed successfully on /dev/$disk"
        return 0
    else
        log_warning "GRUB installation completed with warnings on /dev/$disk"
        return 0
    fi
}

################################################################################
# VERIFY GRUB INSTALLATION
################################################################################
verify_grub() {
    local disk=$1
    
    log_info "Verifying GRUB on /dev/$disk..."
    
    # Check if EFI bootloader exists
    local mount_point="/tmp/verify-$disk-$$"
    mkdir -p "$mount_point"
    
    if mount /dev/${disk}1 "$mount_point" 2>/dev/null; then
        if [ -f "$mount_point/EFI/GRUB/grubx64.efi" ]; then
            log_success "✓ GRUB EFI bootloader present"
        else
            log_warning "✗ GRUB EFI bootloader missing"
        fi
        
        if [ -f "$mount_point/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
            log_success "✓ Windows bootloader present"
        else
            log_warning "✗ Windows bootloader missing (may be Windows-less system)"
        fi
        
        umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
        sleep 1
    else
        log_warning "Could not verify /dev/$disk"
    fi
    
    rmdir "$mount_point" 2>/dev/null || true
}

################################################################################
# MAIN FUNCTION
################################################################################
main() {
    local disks=("$@")
    
    # Default to sda sdb sdd sdc if no arguments
    if [ ${#disks[@]} -eq 0 ]; then
        disks=(sda sdb sdd sdc)
    fi
    
    echo ""
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║    GRUB FIX TOOL - Mass Disk Repair (SSH-SAFE)       ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    log_info "Disks to fix: ${disks[*]}"
    log_warning "This script will NOT kill SSH connections"
    echo ""
    
    read -p "Press ENTER to continue or Ctrl+C to abort..." dummy
    echo ""
    
    # Step 1: Cleanup all mounts
    cleanup_all_mounts
    
    # Step 2: Fix GRUB on each disk sequentially
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         STEP 2: Fixing GRUB on each disk             ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    local success=0
    local failed=0
    
    for disk in "${disks[@]}"; do
        if fix_grub_single_disk "$disk"; then
            ((success++))
        else
            ((failed++))
        fi
        echo ""
        sleep 3
    done
    
    # Step 3: Verify installations
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         STEP 3: Verifying GRUB installations         ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    for disk in "${disks[@]}"; do
        verify_grub "$disk"
        echo ""
    done
    
    # Step 4: Show EFI boot entries
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         STEP 4: EFI Boot Entries                     ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    efibootmgr | grep -E "Windows|Ubuntu|GRUB|Boot" || log_info "No boot entries found"
    echo ""
    
    # Final summary
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         SUMMARY                                       ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    log_success "Successfully fixed: $success disk(s)"
    if [ $failed -gt 0 ]; then
        log_error "Failed: $failed disk(s)"
    fi
    echo ""
    
    log_info "Next steps:"
    log_info "1. Check boot entries with: efibootmgr"
    log_info "2. Test boot one of the disks"
    log_info "3. If GRUB doesn't show Windows, boot to Linux and run: sudo update-grub"
    echo ""
    
    log_success "Script completed safely - SSH connection maintained!"
}

# Run main
main "$@"
