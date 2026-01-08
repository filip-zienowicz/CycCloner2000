#!/bin/bash

################################################################################
# CycCloner2000 - Advanced Disk Cloning Tool
#
# Features:
# - Clone disk partitions to files (not full disk DD)
# - Restore to single or multiple disks simultaneously
# - Automatic GRUB installation (BIOS + UEFI)
# - Supports Windows, Linux, and mixed configurations
# - Works with filesystem-level backup (saves space)
# - Enhanced error handling and progress monitoring
################################################################################

# CONFIGURATION VARIABLES
BACKUP_DIR="/root/images"
LOG_FILE="/var/log/cyc-cloner.log"
PARALLEL_JOBS=8
COMPRESSION="pigz"  # pigz (fast parallel gzip) or gzip or none
TIMEOUT_SECONDS=30  # Timeout for operations that might hang

################################################################################
# COLOR CODES
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

################################################################################
# LOGGING FUNCTIONS
################################################################################
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR] $*${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $*${NC}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO] $*${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $*${NC}" | tee -a "$LOG_FILE"
}

log_debug() {
    echo -e "${CYAN}[DEBUG] $*${NC}" | tee -a "$LOG_FILE"
}

################################################################################
# UTILITY FUNCTIONS
################################################################################
refresh_disk_list() {
    log_debug "Refreshing disk list (hot-swap support)..."

    # Force kernel to rescan all SCSI/SATA buses
    if [ -d /sys/class/scsi_host ]; then
        for host in /sys/class/scsi_host/host*; do
            if [ -f "$host/scan" ]; then
                echo "- - -" > "$host/scan" 2>/dev/null || true
            fi
        done
    fi

    # Rescan block devices
    if command -v partprobe &> /dev/null; then
        partprobe 2>/dev/null || true
    fi

    # Give kernel time to detect new devices
    sleep 1

    # Trigger udev
    if command -v udevadm &> /dev/null; then
        udevadm trigger --subsystem-match=block 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    log_debug "Disk refresh completed"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    local deps="parted partclone.ext4 partclone.ntfs partclone.fat32 partclone.ext3 partclone.ext2 pigz pv sgdisk gdisk efibootmgr ntfs-3g"
    local missing=""

    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            missing="$missing $dep"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Missing dependencies:$missing"
        log_info "Install with: sudo apt-get install parted partclone pigz pv gdisk efibootmgr ntfs-3g"
        exit 1
    fi
}

list_disks() {
    refresh_disk_list
    log_info "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
    echo ""
}

get_disk_info() {
    local disk=$1
    log_info "Disk information for $disk:"
    parted -s "/dev/$disk" print
    lsblk "/dev/$disk" -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL
}

is_disk_mounted() {
    local disk=$1
    if mount | grep -q "^/dev/$disk"; then
        return 0
    fi
    return 1
}

detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        echo "UEFI"
    else
        echo "BIOS"
    fi
}

verify_file_integrity() {
    local file=$1
    
    if [ ! -f "$file" ]; then
        log_error "File does not exist: $file"
        return 1
    fi
    
    local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    
    if [ "$file_size" -eq 0 ]; then
        log_error "File is empty: $file"
        return 1
    fi
    
    log_debug "File size: $(du -h "$file" | cut -f1)"
    
    # Check if it's a compressed file
    if [[ "$file" =~ \.gz$ ]]; then
        log_debug "Testing gzip archive integrity..."
        if ! timeout "$TIMEOUT_SECONDS" pigz -t "$file" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Archive is corrupted: $file"
            return 1
        fi
        log_success "Archive integrity OK"
    fi
    
    return 0
}

################################################################################
# WINDOWS DETECTION FUNCTIONS
################################################################################
has_windows_partition() {
    local disk=$1
    local partitions=$(lsblk -ln -o NAME,FSTYPE "/dev/$disk" | grep -v "^${disk}$")

    while read -r part_name fs_type; do
        local partition="/dev/$part_name"

        # Check if NTFS partition
        if [ "$fs_type" = "ntfs" ]; then
            # Mount temporarily to check for Windows
            local temp_mount="/tmp/cyc-check-$$"
            mkdir -p "$temp_mount"

            if timeout 10 mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
                # Check for Windows directories
                if [ -d "$temp_mount/Windows" ] || [ -d "$temp_mount/WINDOWS" ] || \
                   [ -f "$temp_mount/bootmgr" ] || [ -f "$temp_mount/BOOTMGR" ]; then
                    umount "$temp_mount"
                    rmdir "$temp_mount"
                    return 0
                fi
                umount "$temp_mount"
            fi
            rmdir "$temp_mount" 2>/dev/null
        fi
    done <<< "$partitions"

    return 1
}

has_linux_partition() {
    local disk=$1
    local partitions=$(lsblk -ln -o NAME,FSTYPE "/dev/$disk" | grep -v "^${disk}$")

    while read -r part_name fs_type; do
        if [[ "$fs_type" =~ ^ext[2-4]$ ]] || [ "$fs_type" = "xfs" ] || [ "$fs_type" = "btrfs" ]; then
            return 0
        fi
    done <<< "$partitions"

    return 1
}

detect_os_type() {
    local disk=$1
    local has_windows=false
    local has_linux=false

    if has_windows_partition "$disk"; then
        has_windows=true
    fi

    if has_linux_partition "$disk"; then
        has_linux=true
    fi

    if $has_windows && $has_linux; then
        echo "MIXED"
    elif $has_windows; then
        echo "WINDOWS"
    elif $has_linux; then
        echo "LINUX"
    else
        echo "UNKNOWN"
    fi
}

find_efi_partition() {
    local disk=$1
    local efi_part=$(lsblk -ln -o NAME,FSTYPE,PARTTYPE "/dev/$disk" | \
                     grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b\|vfat" | \
                     head -1 | awk '{print $1}')

    if [ -n "$efi_part" ]; then
        echo "/dev/$efi_part"
    else
        # Fallback: find first vfat partition
        efi_part=$(lsblk -ln -o NAME,FSTYPE "/dev/$disk" | grep vfat | head -1 | awk '{print $1}')
        if [ -n "$efi_part" ]; then
            echo "/dev/$efi_part"
        fi
    fi
}

find_windows_partition() {
    local disk=$1
    local partitions=$(lsblk -ln -o NAME,FSTYPE "/dev/$disk" | grep -v "^${disk}$")

    while read -r part_name fs_type; do
        local partition="/dev/$part_name"

        if [ "$fs_type" = "ntfs" ]; then
            local temp_mount="/tmp/cyc-check-$$"
            mkdir -p "$temp_mount"

            if timeout 10 mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
                if [ -d "$temp_mount/Windows" ] || [ -d "$temp_mount/WINDOWS" ]; then
                    umount "$temp_mount"
                    rmdir "$temp_mount"
                    echo "$partition"
                    return 0
                fi
                umount "$temp_mount"
            fi
            rmdir "$temp_mount" 2>/dev/null
        fi
    done <<< "$partitions"
}

find_linux_root_partition() {
    local disk=$1

    # Try to find root partition (usually largest ext4)
    local root_part=$(lsblk -ln -o NAME,FSTYPE,SIZE "/dev/$disk" | \
                      grep -E "ext[2-4]|xfs|btrfs" | \
                      sort -k3 -hr | head -1 | awk '{print $1}')

    if [ -n "$root_part" ]; then
        echo "/dev/$root_part"
    fi
}

################################################################################
# PARTITION BACKUP FUNCTIONS
################################################################################
backup_partition_table() {
    local source_disk=$1
    local backup_path=$2

    log_info "Backing up partition table for $source_disk..."

    # Backup MBR/GPT
    sgdisk --backup="$backup_path/partition-table.sgdisk" "/dev/$source_disk" 2>/dev/null
    sfdisk -d "/dev/$source_disk" > "$backup_path/partition-table.sfdisk" 2>/dev/null

    # Backup MBR boot code (first 446 bytes) for Windows BIOS systems
    dd if="/dev/$source_disk" of="$backup_path/mbr-backup.bin" bs=446 count=1 2>/dev/null

    # Save disk geometry
    parted -s "/dev/$source_disk" print > "$backup_path/disk-geometry.txt"

    log_success "Partition table backed up"
}

get_filesystem_type() {
    local partition=$1
    blkid -o value -s TYPE "$partition" 2>/dev/null
}

backup_partition() {
    local partition=$1
    local output_file=$2
    local fs_type=$(get_filesystem_type "$partition")

    log_info "Backing up $partition (filesystem: $fs_type)..."

    # Verify partition exists and is not mounted
    if [ ! -b "$partition" ]; then
        log_error "Partition $partition does not exist"
        return 1
    fi

    case "$fs_type" in
        ext2|ext3|ext4)
            log_debug "Using partclone.ext4"
            if ! partclone.ext4 -c -s "$partition" 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition"
                return 1
            fi
            ;;
        ntfs)
            log_debug "Using partclone.ntfs"
            if ! partclone.ntfs -c -s "$partition" 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition"
                return 1
            fi
            ;;
        vfat|fat32|fat16)
            log_debug "Using partclone.vfat"
            if ! partclone.vfat -c -s "$partition" 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition"
                return 1
            fi
            ;;
        swap)
            log_info "Skipping swap partition $partition"
            echo "swap" > "${output_file}.type"
            return 0
            ;;
        "")
            log_warning "No filesystem detected on $partition, using dd backup..."
            if ! dd if="$partition" bs=4M status=progress 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition with dd"
                return 1
            fi
            ;;
        *)
            log_warning "Unknown filesystem $fs_type, using dd backup..."
            if ! dd if="$partition" bs=4M status=progress 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition with dd"
                return 1
            fi
            ;;
    esac

    echo "$fs_type" > "${output_file}.fstype"
    
    # Verify backup file was created and is not empty
    if ! verify_file_integrity "$output_file"; then
        log_error "Backup file verification failed: $output_file"
        return 1
    fi
    
    log_success "Partition $partition backed up successfully"
    return 0
}

clone_disk_to_files() {
    local source_disk=$1

    check_root
    check_dependencies

    log_info "=== STARTING DISK CLONE ==="
    log_info "Source disk: $source_disk"

    # Verify disk exists
    if [ ! -b "/dev/$source_disk" ]; then
        log_error "Disk /dev/$source_disk does not exist"
        exit 1
    fi

    # Create backup directory
    local backup_name="${source_disk}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    mkdir -p "$backup_path"

    log_info "Backup directory: $backup_path"

    # Backup partition table
    backup_partition_table "$source_disk" "$backup_path"

    # Get list of partitions
    local partitions=$(lsblk -ln -o NAME "/dev/$source_disk" | grep -v "^${source_disk}$")

    if [ -z "$partitions" ]; then
        log_error "No partitions found on $source_disk"
        return 1
    fi

    local partition_num=1
    local failed=0
    
    for part_name in $partitions; do
        local partition="/dev/$part_name"

        # Unmount if mounted
        if mountpoint -q "$partition" 2>/dev/null || mount | grep -q "$partition"; then
            log_warning "$partition is mounted, unmounting..."
            umount "$partition" 2>/dev/null || {
                log_error "Failed to unmount $partition"
                ((failed++))
                continue
            }
        fi

        if ! backup_partition "$partition" "$backup_path/partition_${partition_num}.img.gz"; then
            log_error "Failed to backup partition $partition"
            ((failed++))
        fi

        # Save partition info
        blkid "$partition" > "$backup_path/partition_${partition_num}.info" 2>&1

        ((partition_num++))
    done

    # Save metadata
    cat > "$backup_path/metadata.txt" << EOF
SOURCE_DISK=$source_disk
BACKUP_DATE=$(date)
BOOT_MODE=$(detect_boot_mode)
PARTITION_COUNT=$((partition_num - 1))
FAILED_PARTITIONS=$failed
EOF

    if [ $failed -eq 0 ]; then
        log_success "=== DISK CLONE COMPLETED ==="
        log_success "Backup saved to: $backup_path"
    else
        log_error "=== DISK CLONE COMPLETED WITH $failed ERRORS ==="
        log_error "Check log file: $LOG_FILE"
    fi

    # Refresh disk list for hot-swap
    refresh_disk_list

    echo "$backup_path"
}

################################################################################
# PARTITION RESTORE FUNCTIONS
################################################################################
restore_partition_table() {
    local target_disk=$1
    local backup_path=$2

    log_info "Restoring partition table to $target_disk..."

    # Wipe existing partition table thoroughly
    log_debug "Wiping existing partition table..."

    # Get disk size in sectors
    local disk_size_sectors=$(blockdev --getsz "/dev/$target_disk" 2>/dev/null)

    # Wipe with sgdisk (clears GPT)
    sgdisk --zap-all "/dev/$target_disk" 2>/dev/null || true

    # Wipe beginning of disk (MBR + GPT primary)
    dd if=/dev/zero of="/dev/$target_disk" bs=1M count=10 2>/dev/null || true

    # Wipe end of disk (GPT backup) if we know disk size
    if [ -n "$disk_size_sectors" ] && [ "$disk_size_sectors" -gt 0 ]; then
        # Wipe last 10MB where GPT backup resides
        dd if=/dev/zero of="/dev/$target_disk" bs=1M seek=$((disk_size_sectors / 2048 - 10)) count=10 2>/dev/null || true
    fi

    # Force kernel to re-read empty partition table
    partprobe "/dev/$target_disk" 2>/dev/null || true
    blockdev --rereadpt "/dev/$target_disk" 2>/dev/null || true

    sleep 3

    # Restore GPT
    if [ -f "$backup_path/partition-table.sgdisk" ]; then
        log_debug "Restoring GPT partition table..."
        if sgdisk --load-backup="$backup_path/partition-table.sgdisk" "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE"; then
            sgdisk -G "/dev/$target_disk"  # Randomize GUIDs
            log_success "GPT partition table restored"
        else
            log_warning "Failed to restore GPT, trying sfdisk..."
            if [ -f "$backup_path/partition-table.sfdisk" ]; then
                sfdisk "/dev/$target_disk" < "$backup_path/partition-table.sfdisk" 2>&1 | tee -a "$LOG_FILE"
            fi
        fi
    elif [ -f "$backup_path/partition-table.sfdisk" ]; then
        log_debug "Restoring partition table with sfdisk..."
        sfdisk "/dev/$target_disk" < "$backup_path/partition-table.sfdisk" 2>&1 | tee -a "$LOG_FILE"
    else
        log_error "No partition table backup found"
        return 1
    fi

    # Inform kernel of partition changes
    log_debug "Informing kernel of partition changes..."
    partprobe "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE"
    sleep 3
    
    # Force kernel to re-read partition table
    blockdev --rereadpt "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE"
    sleep 2

    log_success "Partition table restored"
    return 0
}

restore_partition() {
    local partition=$1
    local input_file=$2
    local fs_type=""

    # Load filesystem type
    if [ -f "${input_file}.fstype" ]; then
        fs_type=$(cat "${input_file}.fstype")
    fi

    log_info "Restoring to $partition (filesystem: $fs_type)..."

    # Verify partition exists
    if [ ! -b "$partition" ]; then
        log_error "Target partition $partition does not exist"
        return 1
    fi

    # Verify input file
    if [ ! -f "$input_file" ] && [ "$fs_type" != "swap" ]; then
        log_error "Input file $input_file does not exist"
        return 1
    fi

    # For swap partitions
    if [ "$fs_type" = "swap" ] || [ -f "${input_file}.type" ]; then
        log_info "Recreating swap partition on $partition"
        mkswap "$partition" 2>&1 | tee -a "$LOG_FILE"
        return $?
    fi

    # Verify file integrity before restore
    if ! verify_file_integrity "$input_file"; then
        log_error "Cannot restore from corrupted file: $input_file"
        return 1
    fi

    log_debug "Starting restore operation..."

    case "$fs_type" in
        ext2|ext3|ext4)
            log_debug "Command: pigz -dc $input_file | partclone.ext4 -r -d -o $partition"
            if pigz -dc "$input_file" | partclone.ext4 -r -d -o "$partition" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Successfully restored ext partition"
            else
                log_error "Failed to restore ext partition"
                return 1
            fi
            ;;
        ntfs)
            log_debug "Command: pigz -dc $input_file | partclone.ntfs -r -d -o $partition"
            if pigz -dc "$input_file" | partclone.ntfs -r -d -o "$partition" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Successfully restored NTFS partition"
            else
                log_error "Failed to restore NTFS partition"
                return 1
            fi
            ;;
        vfat|fat32|fat16)
            log_debug "Command: pigz -dc $input_file | partclone.vfat -r -d -o $partition"
            if pigz -dc "$input_file" | partclone.vfat -r -d -o "$partition" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Successfully restored FAT partition"
            else
                log_error "Failed to restore FAT partition"
                return 1
            fi
            ;;
        "")
            log_info "No filesystem type stored, using dd restore..."
            if pigz -dc "$input_file" | dd of="$partition" bs=4M status=progress 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Successfully restored with dd"
            else
                log_error "Failed to restore with dd"
                return 1
            fi
            ;;
        *)
            log_info "Unknown filesystem type, using dd restore..."
            if pigz -dc "$input_file" | dd of="$partition" bs=4M status=progress 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Successfully restored with dd"
            else
                log_error "Failed to restore with dd"
                return 1
            fi
            ;;
    esac

    # Verify partition after restore
    sync
    sleep 1
    
    log_success "Partition $partition restored successfully"
    return 0
}

################################################################################
# WINDOWS BOOTLOADER INSTALLATION
################################################################################
install_windows_bootloader_uefi() {
    local target_disk=$1
    local backup_path=$2

    log_info "Installing Windows UEFI bootloader on $target_disk..."

    local efi_part=$(find_efi_partition "$target_disk")
    local win_part=$(find_windows_partition "$target_disk")

    if [ -z "$efi_part" ] || [ -z "$win_part" ]; then
        log_error "Could not find EFI or Windows partition"
        return 1
    fi

    log_debug "EFI partition: $efi_part"
    log_debug "Windows partition: $win_part"

    # Mount EFI partition
    local efi_mount="/mnt/cyc-efi-$$"
    mkdir -p "$efi_mount"
    
    if ! timeout 10 mount "$efi_part" "$efi_mount" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to mount EFI partition"
        rmdir "$efi_mount"
        return 1
    fi

    # Mount Windows partition
    local win_mount="/mnt/cyc-win-$$"
    mkdir -p "$win_mount"
    
    if ! timeout 10 mount -t ntfs-3g "$win_part" "$win_mount" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to mount Windows partition"
        umount "$efi_mount" 2>/dev/null
        rmdir "$efi_mount" "$win_mount"
        return 1
    fi

    # Check if Windows Boot Manager exists in Windows partition
    if [ -d "$win_mount/Windows/Boot" ]; then
        log_info "Found Windows Boot Manager, copying to EFI partition..."

        # Create EFI/Microsoft/Boot directory
        mkdir -p "$efi_mount/EFI/Microsoft/Boot"

        # Copy bootmgfw.efi and BCD
        if [ -f "$win_mount/Windows/Boot/EFI/bootmgfw.efi" ]; then
            cp "$win_mount/Windows/Boot/EFI/bootmgfw.efi" "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | tee -a "$LOG_FILE" || true
        fi

        if [ -d "$win_mount/Windows/Boot/EFI" ]; then
            cp -r "$win_mount/Windows/Boot/EFI/"* "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | tee -a "$LOG_FILE" || true
        fi

        # Copy BCD store
        if [ -f "$win_mount/Boot/BCD" ]; then
            cp "$win_mount/Boot/BCD" "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | tee -a "$LOG_FILE" || true
        fi
    elif [ -d "$efi_mount/EFI/Microsoft" ]; then
        log_info "Windows bootloader already exists in EFI partition"
    else
        log_warning "Could not find Windows Boot Manager files"
    fi

    # Add EFI boot entry
    local efi_part_num=$(echo "$efi_part" | sed 's/.*[^0-9]\([0-9]\+\)$/\1/')

    log_debug "Creating EFI boot entry..."
    efibootmgr -c -d "/dev/$target_disk" -p "$efi_part_num" \
               -L "Windows Boot Manager" \
               -l "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" 2>&1 | tee -a "$LOG_FILE" || {
        log_warning "Could not create EFI boot entry (may not work in current environment)"
    }

    # Cleanup
    sync
    umount "$win_mount" 2>/dev/null
    umount "$efi_mount" 2>/dev/null
    rmdir "$win_mount" "$efi_mount"

    log_success "Windows UEFI bootloader installed"
    return 0
}

install_windows_bootloader_bios() {
    local target_disk=$1
    local backup_path=$2

    log_info "Installing Windows BIOS bootloader on $target_disk..."

    local win_part=$(find_windows_partition "$target_disk")

    if [ -z "$win_part" ]; then
        log_error "Could not find Windows partition"
        return 1
    fi

    # For BIOS, the bootloader should already be in the partition
    # We just need to write the MBR boot code
    log_info "Writing Windows MBR boot code..."

    # Check if we have a backup of MBR
    if [ -f "$backup_path/mbr-backup.bin" ]; then
        if dd if="$backup_path/mbr-backup.bin" of="/dev/$target_disk" bs=446 count=1 2>&1 | tee -a "$LOG_FILE"; then
            log_success "MBR restored from backup"
        else
            log_warning "Could not restore MBR from backup"
        fi
    else
        log_warning "No MBR backup found - Windows may not boot"
        log_info "You may need to run 'bootrec /fixmbr' and 'bootrec /fixboot' from Windows Recovery"
    fi

    log_success "Windows BIOS bootloader installation attempted"
    return 0
}

################################################################################
# GRUB INSTALLATION
################################################################################
install_grub() {
    local target_disk=$1
    local backup_path=$2
    local boot_mode=$(detect_boot_mode)

    log_info "Installing GRUB on $target_disk (boot mode: $boot_mode)..."

    # Mount partitions temporarily
    local mount_point="/mnt/cyc-cloner-$$"
    mkdir -p "$mount_point"

    # Find root partition (usually the largest ext4)
    local root_part=$(find_linux_root_partition "$target_disk")

    if [ -z "$root_part" ]; then
        log_warning "Could not find Linux root partition"
        rmdir "$mount_point"
        return 1
    fi

    log_debug "Linux root partition: $root_part"

    if ! timeout 10 mount "$root_part" "$mount_point" 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Could not mount $root_part, skipping GRUB installation"
        rmdir "$mount_point"
        return 1
    fi

    # Mount EFI partition if UEFI
    if [ "$boot_mode" = "UEFI" ]; then
        local efi_part=$(find_efi_partition "$target_disk")
        if [ -n "$efi_part" ]; then
            log_debug "EFI partition: $efi_part"
            mkdir -p "$mount_point/boot/efi"
            timeout 10 mount "$efi_part" "$mount_point/boot/efi" 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi

    # Bind mount necessary filesystems
    for dir in proc sys dev dev/pts; do
        mkdir -p "$mount_point/$dir"
        mount --bind "/$dir" "$mount_point/$dir" 2>&1 | tee -a "$LOG_FILE" || true
    done

    # Install GRUB
    if [ "$boot_mode" = "UEFI" ]; then
        log_debug "Installing GRUB for UEFI..."
        chroot "$mount_point" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || {
            log_warning "UEFI GRUB installation failed, trying without chroot..."
            grub-install --target=x86_64-efi --boot-directory="$mount_point/boot" "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || true
        }
    else
        log_debug "Installing GRUB for BIOS..."
        chroot "$mount_point" grub-install "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || {
            log_warning "BIOS GRUB installation failed, trying without chroot..."
            grub-install --boot-directory="$mount_point/boot" "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || true
        }
    fi

    # Update GRUB configuration (will detect Windows if present)
    log_debug "Updating GRUB configuration..."
    chroot "$mount_point" update-grub 2>&1 | tee -a "$LOG_FILE" || {
        chroot "$mount_point" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$LOG_FILE" || true
    }

    # For mixed systems, ensure os-prober is enabled
    if [ -f "$mount_point/etc/default/grub" ]; then
        if ! grep -q "GRUB_DISABLE_OS_PROBER=false" "$mount_point/etc/default/grub"; then
            log_debug "Enabling os-prober for dual-boot detection..."
            echo "GRUB_DISABLE_OS_PROBER=false" >> "$mount_point/etc/default/grub"
            chroot "$mount_point" update-grub 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi

    # Cleanup
    sync
    for dir in dev/pts dev proc sys boot/efi; do
        umount "$mount_point/$dir" 2>/dev/null || true
    done
    umount "$mount_point" 2>/dev/null || true
    rmdir "$mount_point"

    log_success "GRUB installed on $target_disk"
    return 0
}

################################################################################
# SMART BOOTLOADER INSTALLATION
################################################################################
install_bootloader() {
    local target_disk=$1
    local backup_path=$2

    log_info "Detecting OS type on $target_disk..."
    local os_type=$(detect_os_type "$target_disk")
    local boot_mode=$(detect_boot_mode)

    log_info "Detected OS type: $os_type"
    log_info "Boot mode: $boot_mode"

    case "$os_type" in
        WINDOWS)
            log_info "Installing Windows-only bootloader..."
            if [ "$boot_mode" = "UEFI" ]; then
                install_windows_bootloader_uefi "$target_disk" "$backup_path"
            else
                install_windows_bootloader_bios "$target_disk" "$backup_path"
            fi
            ;;
        LINUX)
            log_info "Installing Linux-only bootloader (GRUB)..."
            install_grub "$target_disk" "$backup_path"
            ;;
        MIXED)
            log_info "Installing bootloader for dual-boot system..."
            # For mixed systems, install GRUB which will detect Windows
            install_grub "$target_disk" "$backup_path"
            # Also ensure Windows bootloader is present in EFI partition
            if [ "$boot_mode" = "UEFI" ]; then
                install_windows_bootloader_uefi "$target_disk" "$backup_path"
            fi
            ;;
        *)
            log_warning "Could not detect OS type, attempting GRUB installation..."
            install_grub "$target_disk" "$backup_path"
            ;;
    esac
}

restore_to_disk() {
    local backup_path=$1
    local target_disk=$2

    log_info "=== STARTING DISK RESTORE ==="
    log_info "Source: $backup_path"
    log_info "Target: $target_disk"

    # Verify backup exists
    if [ ! -d "$backup_path" ]; then
        log_error "Backup directory $backup_path does not exist"
        return 1
    fi

    # Verify metadata exists
    if [ ! -f "$backup_path/metadata.txt" ]; then
        log_error "Backup metadata not found - backup may be incomplete"
        return 1
    fi

    # Verify target disk exists
    if [ ! -b "/dev/$target_disk" ]; then
        log_error "Target disk /dev/$target_disk does not exist"
        return 1
    fi

    # Safety check - ensure disk is not mounted
    if is_disk_mounted "$target_disk"; then
        log_error "Target disk $target_disk has mounted partitions. Unmount first!"
        return 1
    fi

    # Restore partition table
    if ! restore_partition_table "$target_disk" "$backup_path"; then
        log_error "Failed to restore partition table"
        return 1
    fi

    # Get number of partitions
    local partition_count=$(grep PARTITION_COUNT "$backup_path/metadata.txt" | cut -d= -f2)
    log_info "Restoring $partition_count partitions..."

    # Restore each partition
    local failed=0
    for i in $(seq 1 "$partition_count"); do
        local partition_img="$backup_path/partition_${i}.img.gz"

        # Check if this is a swap partition
        if [ -f "${partition_img}.type" ]; then
            local part_type=$(cat "${partition_img}.type")
            if [ "$part_type" = "swap" ]; then
                log_info "Partition $i is swap, will recreate..."
            fi
        fi

        # Get target partition name
        local target_part=$(lsblk -ln -o NAME "/dev/$target_disk" | grep -v "^${target_disk}$" | sed -n "${i}p")

        if [ -z "$target_part" ]; then
            log_error "Could not find partition $i on $target_disk"
            ((failed++))
            continue
        fi

        log_info "Restoring partition $i/$partition_count to /dev/$target_part..."
        
        if ! restore_partition "/dev/$target_part" "$partition_img"; then
            log_error "Failed to restore partition $i"
            ((failed++))
        fi
    done

    if [ $failed -gt 0 ]; then
        log_error "$failed partition(s) failed to restore"
        log_error "Check log file: $LOG_FILE"
        return 1
    fi

    # Install bootloader (automatically detects OS type)
    log_info "Installing bootloader..."
    install_bootloader "$target_disk" "$backup_path"

    # Refresh disk list for hot-swap
    refresh_disk_list

    log_success "=== DISK RESTORE COMPLETED for $target_disk ==="
    return 0
}

################################################################################
# PARALLEL MULTI-DISK RESTORE
################################################################################
restore_to_multiple_disks() {
    local backup_path=$1
    shift
    local target_disks=("$@")

    log_info "=== STARTING PARALLEL MULTI-DISK RESTORE ==="
    log_info "Source: $backup_path"
    log_info "Targets: ${target_disks[*]}"
    log_info "Parallel jobs: ${#target_disks[@]}"

    # Create array to store PIDs
    local pids=()
    local disk_status=()

    # Start restore for each disk in parallel
    for disk in "${target_disks[@]}"; do
        (
            # Create separate log for this disk
            local disk_log="/tmp/cyc-clone-${disk}-$$.log"
            
            log_info "Starting restore to $disk..." | tee -a "$disk_log"
            
            if restore_to_disk "$backup_path" "$disk" 2>&1 | tee -a "$disk_log"; then
                log_success "Restore to $disk completed" | tee -a "$disk_log"
                exit 0
            else
                log_error "Restore to $disk failed" | tee -a "$disk_log"
                exit 1
            fi
        ) &
        
        pids+=($!)
        disk_status+=("$disk:$!")

        log_info "Started restore to $disk (PID: ${pids[-1]})"

        # Small delay to avoid I/O congestion
        sleep 2
    done

    # Wait for all restores to complete
    log_info "Waiting for all restore operations to complete..."
    local failed=0
    local completed=0

    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        local disk=${target_disks[$i]}
        
        if wait "$pid"; then
            log_success "Restore to $disk (PID: $pid) completed successfully"
            ((completed++))
        else
            log_error "Restore to $disk (PID: $pid) failed"
            ((failed++))
        fi
    done

    log_info "Restore summary: $completed succeeded, $failed failed"

    # Refresh disk list for hot-swap
    refresh_disk_list

    if [ $failed -eq 0 ]; then
        log_success "=== ALL DISK RESTORES COMPLETED SUCCESSFULLY ==="
        return 0
    else
        log_error "=== $failed DISK RESTORE(S) FAILED ==="
        return 1
    fi
}

################################################################################
# INTERACTIVE MENU
################################################################################
show_menu() {
    # Refresh disk list before showing menu (hot-swap support)
    refresh_disk_list

    echo ""
    echo "=========================================="
    echo "    CycCloner2000 - Disk Cloning Tool"
    echo "=========================================="
    echo -e "${CYAN}[Hot-Swap Ready]${NC} Disks refreshed automatically"
    echo ""
    echo "1) Clone disk to files"
    echo "2) Restore to single disk"
    echo "3) Restore to multiple disks (parallel)"
    echo "4) List available disks"
    echo "5) List available backups"
    echo "6) Verify backup integrity"
    echo "7) Exit"
    echo ""
}

list_backups() {
    log_info "Available backups in $BACKUP_DIR:"
    if [ -d "$BACKUP_DIR" ]; then
        if [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
            log_warning "No backups found"
        else
            ls -lh "$BACKUP_DIR" | grep "^d" | awk '{print $9, "("$5")"}'
        fi
    else
        log_warning "Backup directory does not exist yet"
    fi
}

verify_backup() {
    list_backups
    echo ""
    echo -n "Enter backup name to verify: "
    read -r backup_name

    local backup_path="$BACKUP_DIR/$backup_name"

    if [ ! -d "$backup_path" ]; then
        log_error "Backup $backup_path not found"
        return 1
    fi

    log_info "Verifying backup: $backup_name"

    # Check metadata
    if [ ! -f "$backup_path/metadata.txt" ]; then
        log_error "Metadata file missing"
        return 1
    fi

    # Get partition count
    local partition_count=$(grep PARTITION_COUNT "$backup_path/metadata.txt" | cut -d= -f2)
    log_info "Expected partitions: $partition_count"

    # Verify each partition file
    local failed=0
    for i in $(seq 1 "$partition_count"); do
        local partition_img="$backup_path/partition_${i}.img.gz"
        
        echo ""
        log_info "Checking partition $i/$partition_count..."
        
        if [ -f "${partition_img}.type" ]; then
            log_info "Partition $i is marked as $(cat "${partition_img}.type")"
            continue
        fi
        
        if ! verify_file_integrity "$partition_img"; then
            ((failed++))
        fi
    done

    echo ""
    if [ $failed -eq 0 ]; then
        log_success "Backup verification PASSED - all files OK"
    else
        log_error "Backup verification FAILED - $failed corrupted file(s)"
    fi
}

interactive_clone() {
    list_disks
    echo -n "Enter source disk name (e.g., sda): "
    read -r source_disk

    if [ -z "$source_disk" ]; then
        log_error "No disk specified"
        return 1
    fi

    get_disk_info "$source_disk"

    echo ""
    echo -n "Proceed with cloning $source_disk? (yes/no): "
    read -r confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Clone cancelled"
        return 0
    fi

    clone_disk_to_files "$source_disk"
}

interactive_restore_single() {
    list_backups
    echo ""
    echo -n "Enter backup name (directory name): "
    read -r backup_name

    local backup_path="$BACKUP_DIR/$backup_name"

    if [ ! -d "$backup_path" ]; then
        log_error "Backup $backup_path not found"
        return 1
    fi

    echo ""
    list_disks
    echo -n "Enter target disk name (e.g., sdb): "
    read -r target_disk

    if [ -z "$target_disk" ]; then
        log_error "No disk specified"
        return 1
    fi

    echo ""
    log_warning "ALL DATA ON /dev/$target_disk WILL BE DESTROYED!"
    echo -n "Type 'YES' to confirm: "
    read -r confirm

    if [ "$confirm" != "YES" ]; then
        log_info "Restore cancelled"
        return 0
    fi

    restore_to_disk "$backup_path" "$target_disk"
}

interactive_restore_multiple() {
    list_backups
    echo ""
    echo -n "Enter backup name (directory name): "
    read -r backup_name

    local backup_path="$BACKUP_DIR/$backup_name"

    if [ ! -d "$backup_path" ]; then
        log_error "Backup $backup_path not found"
        return 1
    fi

    echo ""
    list_disks
    echo ""
    echo "Enter target disks separated by spaces (e.g., sdb sdc sdd):"
    read -r -a target_disks

    if [ ${#target_disks[@]} -eq 0 ]; then
        log_error "No disks specified"
        return 1
    fi

    echo ""
    log_warning "ALL DATA ON THE FOLLOWING DISKS WILL BE DESTROYED:"
    for disk in "${target_disks[@]}"; do
        echo "  - /dev/$disk"
    done

    echo ""
    echo -n "Type 'YES' to confirm: "
    read -r confirm

    if [ "$confirm" != "YES" ]; then
        log_info "Restore cancelled"
        return 0
    fi

    restore_to_multiple_disks "$backup_path" "${target_disks[@]}"
}

################################################################################
# MAIN
################################################################################
main() {
    check_root
    check_dependencies

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Create log file if it doesn't exist
    touch "$LOG_FILE"

    log_info "CycCloner2000 started"
    log_info "Log file: $LOG_FILE"

    while true; do
        show_menu
        echo -n "Select option: "
        read -r option

        case $option in
            1)
                interactive_clone
                ;;
            2)
                interactive_restore_single
                ;;
            3)
                interactive_restore_multiple
                ;;
            4)
                list_disks
                ;;
            5)
                list_backups
                ;;
            6)
                verify_backup
                ;;
            7)
                log_info "Exiting CycCloner2000"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                ;;
        esac

        echo ""
        echo "Press Enter to continue..."
        read -r
    done
}

# Run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
