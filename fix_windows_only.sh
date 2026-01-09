#!/bin/bash

################################################################################
# fix_windows_only.sh - Windows Bootloader Repair Tool
#
# Repairs Windows bootloader on disks with Windows-only installations
# Works with UEFI systems
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
# DETECT WINDOWS PARTITIONS
################################################################################
detect_windows_partitions() {
    local disk=$1
    local efi_part=""
    local win_part=""
    local recovery_part=""
    
    log_info "Detecting Windows partitions on /dev/$disk..."
    
    # Check common Windows layouts
    # Partition 1: EFI (200MB, vfat)
    # Partition 2: MSR (16MB, no filesystem)
    # Partition 3: Windows (NTFS, large)
    # Partition 4: Recovery (NTFS, 746MB-1GB)
    
    # Find EFI partition
    for part in 1 2; do
        if [ -b "/dev/${disk}${part}" ]; then
            local fs_type=$(blkid -o value -s TYPE "/dev/${disk}${part}" 2>/dev/null)
            if [ "$fs_type" = "vfat" ]; then
                efi_part="${disk}${part}"
                log_info "Found EFI partition: /dev/$efi_part"
                break
            fi
        fi
    done
    
    # Find Windows partition (largest NTFS)
    local largest_size=0
    for part in 3 4 5; do
        if [ -b "/dev/${disk}${part}" ]; then
            local fs_type=$(blkid -o value -s TYPE "/dev/${disk}${part}" 2>/dev/null)
            if [ "$fs_type" = "ntfs" ]; then
                local size=$(blockdev --getsize64 "/dev/${disk}${part}" 2>/dev/null || echo 0)
                if [ "$size" -gt "$largest_size" ]; then
                    largest_size=$size
                    win_part="${disk}${part}"
                fi
            fi
        fi
    done
    
    if [ -n "$win_part" ]; then
        log_info "Found Windows partition: /dev/$win_part"
    fi
    
    # Find Recovery partition (small NTFS)
    for part in 4 5; do
        if [ -b "/dev/${disk}${part}" ] && [ "/dev/${disk}${part}" != "/dev/$win_part" ]; then
            local fs_type=$(blkid -o value -s TYPE "/dev/${disk}${part}" 2>/dev/null)
            if [ "$fs_type" = "ntfs" ]; then
                recovery_part="${disk}${part}"
                log_info "Found Recovery partition: /dev/$recovery_part"
                break
            fi
        fi
    done
    
    # Return results
    echo "$efi_part|$win_part|$recovery_part"
}

################################################################################
# FIX WINDOWS BOOTLOADER
################################################################################
fix_windows_bootloader() {
    local disk=$1
    
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║     Fixing Windows bootloader on /dev/$disk          "
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    # Check if disk exists
    if [ ! -b "/dev/$disk" ]; then
        log_error "Disk /dev/$disk does not exist!"
        return 1
    fi
    
    # Detect partitions
    local parts=$(detect_windows_partitions "$disk")
    local efi_part=$(echo "$parts" | cut -d'|' -f1)
    local win_part=$(echo "$parts" | cut -d'|' -f2)
    local recovery_part=$(echo "$parts" | cut -d'|' -f3)
    
    if [ -z "$efi_part" ] || [ -z "$win_part" ]; then
        log_error "Could not find EFI or Windows partition!"
        log_info "This disk may not have a Windows installation"
        return 1
    fi
    
    echo ""
    log_info "Partition layout:"
    log_info "  EFI: /dev/$efi_part"
    log_info "  Windows: /dev/$win_part"
    [ -n "$recovery_part" ] && log_info "  Recovery: /dev/$recovery_part"
    echo ""
    
    # Create mount points
    local efi_mount="/mnt/win-efi-$disk-$$"
    local win_mount="/mnt/win-ntfs-$disk-$$"
    
    mkdir -p "$efi_mount" "$win_mount"
    
    # Mount EFI partition
    log_info "Mounting EFI partition..."
    if ! mount /dev/$efi_part "$efi_mount"; then
        log_error "Failed to mount EFI partition"
        rmdir "$efi_mount" "$win_mount"
        return 1
    fi
    
    # Check if Windows bootloader exists
    log_info "Checking Windows bootloader..."
    
    if [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        log_success "✓ Windows bootloader already present"
        
        # Verify BCD
        if [ -f "$efi_mount/EFI/Microsoft/Boot/BCD" ]; then
            log_success "✓ Boot Configuration Data (BCD) present"
        else
            log_warning "✗ BCD missing - may need restoration"
        fi
    else
        log_warning "✗ Windows bootloader missing"
        log_info "Attempting to restore from Windows partition..."
        
        # Try to mount NTFS and copy bootloader
        log_info "Mounting Windows NTFS partition (read-only)..."
        if mount -t ntfs-3g -o ro /dev/$win_part "$win_mount" 2>/dev/null; then
            
            # Check for Windows Boot files
            if [ -d "$win_mount/Windows/Boot/EFI" ]; then
                log_info "Found Windows Boot files, copying..."
                mkdir -p "$efi_mount/EFI/Microsoft/Boot"
                
                # Copy bootloader files
                cp -rv "$win_mount/Windows/Boot/EFI/"* "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | grep -v "^'" || true
                
                # Copy BCD if exists
                if [ -f "$win_mount/Boot/BCD" ]; then
                    cp -v "$win_mount/Boot/BCD" "$efi_mount/EFI/Microsoft/Boot/" || true
                fi
                
                sync
                log_success "Windows bootloader files copied"
            else
                log_error "Windows Boot files not found in /Windows/Boot/EFI"
                log_info "The Windows installation may be corrupted"
            fi
            
            umount "$win_mount"
        else
            log_error "Failed to mount Windows NTFS partition"
            log_info "The partition may be hibernated or corrupted"
        fi
    fi
    
    echo ""
    
    # Verify bootloader after restoration attempt
    if [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        log_success "✓ Windows bootloader verified"
        
        # Show bootloader info
        log_info "Bootloader details:"
        ls -lh "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" | awk '{print "  Size: " $5 ", Modified: " $6" "$7" "$8}'
        
        # Create/Update EFI boot entry
        log_info "Creating EFI boot entry..."
        
        # Get partition number (extract number from sdX#)
        local part_num=$(echo "$efi_part" | grep -o '[0-9]*$')
        
        # Get PARTUUID
        local part_uuid=$(blkid -s PARTUUID -o value /dev/$efi_part)
        
        # Check if entry already exists
        local existing_entry=$(efibootmgr | grep "Windows Boot Manager" | grep "$part_uuid" | head -1 | cut -d'*' -f1 | sed 's/Boot//')
        
        if [ -n "$existing_entry" ]; then
            log_info "Boot entry already exists (Boot$existing_entry)"
        else
            # Create new entry
            efibootmgr -c -d "/dev/$disk" -p "$part_num" \
                -L "Windows Boot Manager ($disk)" \
                -l "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" 2>&1 | grep -v "Warning" || true
            
            log_success "EFI boot entry created"
        fi
    else
        log_error "Windows bootloader still missing after restoration attempt"
        log_warning "Manual intervention may be required"
    fi
    
    echo ""
    
    # Show all boot files in EFI partition
    log_info "EFI partition contents:"
    if [ -d "$efi_mount/EFI" ]; then
        ls -la "$efi_mount/EFI/" | tail -n +4 | awk '{print "  " $9}' | grep -v "^$"
    fi
    
    # Cleanup
    log_info "Cleaning up..."
    sync
    sleep 2
    
    umount "$efi_mount" 2>/dev/null || umount -l "$efi_mount" 2>/dev/null
    [ -d "$win_mount" ] && rmdir "$win_mount"
    sleep 1
    rmdir "$efi_mount" 2>/dev/null || true
    
    log_success "Windows bootloader fix completed for /dev/$disk"
    echo ""
    
    return 0
}

################################################################################
# VERIFY WINDOWS BOOTLOADER
################################################################################
verify_windows_bootloader() {
    local disk=$1
    
    log_info "Verifying Windows bootloader on /dev/$disk..."
    
    # Detect partitions
    local parts=$(detect_windows_partitions "$disk")
    local efi_part=$(echo "$parts" | cut -d'|' -f1)
    
    if [ -z "$efi_part" ]; then
        log_warning "Could not find EFI partition"
        return 1
    fi
    
    # Mount and check
    local efi_mount="/tmp/verify-win-$disk-$$"
    mkdir -p "$efi_mount"
    
    if mount /dev/$efi_part "$efi_mount" 2>/dev/null; then
        
        if [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
            log_success "✓ Windows bootloader present"
            
            if [ -f "$efi_mount/EFI/Microsoft/Boot/BCD" ]; then
                log_success "✓ BCD present"
            else
                log_warning "✗ BCD missing"
            fi
        else
            log_error "✗ Windows bootloader missing"
        fi
        
        umount "$efi_mount"
    else
        log_warning "Could not mount EFI partition for verification"
    fi
    
    rmdir "$efi_mount" 2>/dev/null
    echo ""
}

################################################################################
# CLEANUP ALL MOUNTS
################################################################################
cleanup_all_mounts() {
    log_info "Cleaning up any stuck mounts..."
    
    # Unmount any leftover mounts
    for mount in /mnt/win-efi-* /mnt/win-ntfs-* /tmp/verify-win-*; do
        if [ -d "$mount" ]; then
            umount -l "$mount" 2>/dev/null || true
        fi
    done
    
    # Remove directories
    rmdir /mnt/win-efi-* /mnt/win-ntfs-* /tmp/verify-win-* 2>/dev/null || true
    
    log_success "Cleanup complete"
    echo ""
}

################################################################################
# MAIN FUNCTION
################################################################################
main() {
    local disks=("$@")
    
    # If no arguments, show usage
    if [ ${#disks[@]} -eq 0 ]; then
        echo ""
        log_info "╔═══════════════════════════════════════════════════════╗"
        log_info "║  Windows Bootloader Fix Tool                         ║"
        log_info "╚═══════════════════════════════════════════════════════╝"
        echo ""
        log_info "Usage: $0 <disk1> [disk2] [disk3] ..."
        log_info "Example: $0 sda sdb sdc"
        echo ""
        log_info "This script will:"
        log_info "  1. Detect Windows partitions (EFI, NTFS)"
        log_info "  2. Verify Windows bootloader presence"
        log_info "  3. Restore bootloader from Windows partition if missing"
        log_info "  4. Create EFI boot entries"
        echo ""
        exit 1
    fi
    
    echo ""
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║  Windows Bootloader Fix Tool                         ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    log_info "Disks to fix: ${disks[*]}"
    echo ""
    
    read -p "Press ENTER to continue or Ctrl+C to abort..." dummy
    echo ""
    
    # Cleanup any previous mounts
    cleanup_all_mounts
    
    # Fix each disk
    local success=0
    local failed=0
    
    for disk in "${disks[@]}"; do
        if fix_windows_bootloader "$disk"; then
            ((success++))
        else
            ((failed++))
        fi
        sleep 2
    done
    
    # Verify all disks
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         Verification                                  ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    for disk in "${disks[@]}"; do
        verify_windows_bootloader "$disk"
    done
    
    # Show EFI boot entries
    log_info "╔═══════════════════════════════════════════════════════╗"
    log_info "║         EFI Boot Entries                              ║"
    log_info "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    efibootmgr | grep -E "Windows|Boot" || log_info "No boot entries found"
    echo ""
    
    # Summary
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
    log_info "1. Check boot entries: efibootmgr"
    log_info "2. Test boot from one of the disks"
    log_info "3. If Windows doesn't boot, you may need to:"
    log_info "   - Boot from Windows installation media"
    log_info "   - Run: bootrec /fixboot && bootrec /rebuildbcd"
    echo ""
}

# Run main
main "$@"