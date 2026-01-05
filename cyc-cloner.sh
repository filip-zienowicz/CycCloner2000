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
################################################################################

# CONFIGURATION VARIABLES
BACKUP_DIR="/mnt/backups/disk-images"
LOG_FILE="/var/log/cyc-cloner.log"
PARALLEL_JOBS=8
COMPRESSION="pigz"  # pigz (fast parallel gzip) or gzip or none

################################################################################
# COLOR CODES
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

################################################################################
# UTILITY FUNCTIONS
################################################################################
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    local deps="parted partclone.ext4 partclone.ntfs partclone.fat32 partclone.ext3 partclone.ext2 pigz pv sgdisk gdisk efibootmgr"
    local missing=""

    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            missing="$missing $dep"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Missing dependencies:$missing"
        log_info "Install with: sudo apt-get install parted partclone pigz pv gdisk efibootmgr"
        exit 1
    fi
}

list_disks() {
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

            if mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
                # Check for Windows directories
                if [ -d "$temp_mount/Windows" ] || [ -d "$temp_mount/WINDOWS" ] || \
                   [ -f "$temp_mount/bootmgr" ] || [ -f "$temp_mount/BOOTMGR" ]; then
                    umount "$temp_mount"
                    rmdir "$temp_mount"
                    return 0
                fi
                umount "$temp_mount"
            fi
            rmdir "$temp_mount"
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

            if mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
                if [ -d "$temp_mount/Windows" ] || [ -d "$temp_mount/WINDOWS" ]; then
                    umount "$temp_mount"
                    rmdir "$temp_mount"
                    echo "$partition"
                    return 0
                fi
                umount "$temp_mount"
            fi
            rmdir "$temp_mount"
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
    blkid -o value -s TYPE "$partition"
}

backup_partition() {
    local partition=$1
    local output_file=$2
    local fs_type=$(get_filesystem_type "$partition")

    log_info "Backing up $partition (filesystem: $fs_type)..."

    case "$fs_type" in
        ext2|ext3|ext4)
            partclone.ext4 -c -s "$partition" | pigz -c > "$output_file"
            ;;
        ntfs)
            partclone.ntfs -c -s "$partition" | pigz -c > "$output_file"
            ;;
        vfat|fat32|fat16)
            partclone.vfat -c -s "$partition" | pigz -c > "$output_file"
            ;;
        swap)
            log_info "Skipping swap partition $partition"
            echo "swap" > "${output_file}.type"
            return 0
            ;;
        *)
            log_warning "Unknown filesystem $fs_type, using dd backup..."
            dd if="$partition" bs=4M status=progress | pigz -c > "$output_file"
            ;;
    esac

    echo "$fs_type" > "${output_file}.fstype"
    log_success "Partition $partition backed up"
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

    local partition_num=1
    for part_name in $partitions; do
        local partition="/dev/$part_name"

        # Unmount if mounted
        if mountpoint -q "$partition" 2>/dev/null || mount | grep -q "$partition"; then
            log_warning "$partition is mounted, unmounting..."
            umount "$partition" 2>/dev/null || true
        fi

        backup_partition "$partition" "$backup_path/partition_${partition_num}.img.gz"

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
EOF

    log_success "=== DISK CLONE COMPLETED ==="
    log_success "Backup saved to: $backup_path"

    echo "$backup_path"
}

################################################################################
# PARTITION RESTORE FUNCTIONS
################################################################################
restore_partition_table() {
    local target_disk=$1
    local backup_path=$2

    log_info "Restoring partition table to $target_disk..."

    # Wipe existing partition table
    sgdisk --zap-all "/dev/$target_disk" 2>/dev/null || true

    # Restore GPT
    if [ -f "$backup_path/partition-table.sgdisk" ]; then
        sgdisk --load-backup="$backup_path/partition-table.sgdisk" "/dev/$target_disk"
        sgdisk -G "/dev/$target_disk"  # Randomize GUIDs
    else
        # Fallback to sfdisk
        sfdisk "/dev/$target_disk" < "$backup_path/partition-table.sfdisk"
    fi

    # Inform kernel of partition changes
    partprobe "/dev/$target_disk"
    sleep 2

    log_success "Partition table restored"
}

restore_partition() {
    local partition=$1
    local input_file=$2
    local fs_type=""

    if [ -f "${input_file}.fstype" ]; then
        fs_type=$(cat "${input_file}.fstype")
    fi

    log_info "Restoring to $partition (filesystem: $fs_type)..."

    case "$fs_type" in
        ext2|ext3|ext4)
            pigz -dc "$input_file" | partclone.ext4 -r -o "$partition"
            ;;
        ntfs)
            pigz -dc "$input_file" | partclone.ntfs -r -o "$partition"
            ;;
        vfat|fat32|fat16)
            pigz -dc "$input_file" | partclone.vfat -r -o "$partition"
            ;;
        swap)
            log_info "Recreating swap partition on $partition"
            mkswap "$partition"
            ;;
        *)
            log_info "Restoring with dd..."
            pigz -dc "$input_file" | dd of="$partition" bs=4M status=progress
            ;;
    esac

    log_success "Partition $partition restored"
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

    # Mount EFI partition
    local efi_mount="/mnt/cyc-efi-$$"
    mkdir -p "$efi_mount"
    mount "$efi_part" "$efi_mount" || {
        log_error "Failed to mount EFI partition"
        rmdir "$efi_mount"
        return 1
    }

    # Mount Windows partition
    local win_mount="/mnt/cyc-win-$$"
    mkdir -p "$win_mount"
    mount "$win_part" "$win_mount" || {
        log_error "Failed to mount Windows partition"
        umount "$efi_mount"
        rmdir "$efi_mount" "$win_mount"
        return 1
    }

    # Check if Windows Boot Manager exists in Windows partition
    if [ -d "$win_mount/Windows/Boot" ]; then
        log_info "Found Windows Boot Manager, copying to EFI partition..."

        # Create EFI/Microsoft/Boot directory
        mkdir -p "$efi_mount/EFI/Microsoft/Boot"

        # Copy bootmgfw.efi and BCD
        if [ -f "$win_mount/Windows/Boot/EFI/bootmgfw.efi" ]; then
            cp "$win_mount/Windows/Boot/EFI/bootmgfw.efi" "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        fi

        if [ -d "$win_mount/Windows/Boot/EFI" ]; then
            cp -r "$win_mount/Windows/Boot/EFI/"* "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        fi

        # Copy BCD store
        if [ -f "$win_mount/Windows/Boot/BCD" ]; then
            cp "$win_mount/Windows/Boot/BCD" "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        fi
    elif [ -d "$efi_mount/EFI/Microsoft" ]; then
        log_info "Windows bootloader already exists in EFI partition"
    else
        log_warning "Could not find Windows Boot Manager files"
    fi

    # Add EFI boot entry
    local disk_num=$(echo "$target_disk" | sed 's/[^0-9]*//g')
    local efi_part_num=$(echo "$efi_part" | sed 's/.*[^0-9]\([0-9]\+\)$/\1/')

    efibootmgr -c -d "/dev/$target_disk" -p "$efi_part_num" \
               -L "Windows Boot Manager" \
               -l "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" 2>/dev/null || {
        log_warning "Could not create EFI boot entry (efibootmgr may not work in chroot)"
    }

    # Cleanup
    umount "$win_mount" "$efi_mount"
    rmdir "$win_mount" "$efi_mount"

    log_success "Windows UEFI bootloader installed"
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
        dd if="$backup_path/mbr-backup.bin" of="/dev/$target_disk" bs=446 count=1 2>/dev/null || {
            log_warning "Could not restore MBR from backup"
        }
    else
        log_warning "No MBR backup found - Windows may not boot"
        log_info "You may need to run 'bootrec /fixmbr' and 'bootrec /fixboot' from Windows Recovery"
    fi

    log_success "Windows BIOS bootloader installation attempted"
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

    mount "$root_part" "$mount_point" 2>/dev/null || {
        log_warning "Could not mount $root_part, skipping GRUB installation"
        rmdir "$mount_point"
        return 1
    }

    # Mount EFI partition if UEFI
    if [ "$boot_mode" = "UEFI" ]; then
        local efi_part=$(find_efi_partition "$target_disk")
        if [ -n "$efi_part" ]; then
            mkdir -p "$mount_point/boot/efi"
            mount "$efi_part" "$mount_point/boot/efi" 2>/dev/null || true
        fi
    fi

    # Bind mount necessary filesystems
    for dir in proc sys dev dev/pts; do
        mkdir -p "$mount_point/$dir"
        mount --bind "/$dir" "$mount_point/$dir" 2>/dev/null || true
    done

    # Install GRUB
    if [ "$boot_mode" = "UEFI" ]; then
        chroot "$mount_point" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "/dev/$target_disk" 2>/dev/null || {
            log_warning "UEFI GRUB installation failed, trying without chroot..."
            grub-install --target=x86_64-efi --boot-directory="$mount_point/boot" "/dev/$target_disk" 2>/dev/null || true
        }
    else
        chroot "$mount_point" grub-install "/dev/$target_disk" 2>/dev/null || {
            log_warning "BIOS GRUB installation failed, trying without chroot..."
            grub-install --boot-directory="$mount_point/boot" "/dev/$target_disk" 2>/dev/null || true
        }
    fi

    # Update GRUB configuration (will detect Windows if present)
    chroot "$mount_point" update-grub 2>/dev/null || {
        chroot "$mount_point" grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    }

    # For mixed systems, ensure os-prober is enabled
    if [ -f "$mount_point/etc/default/grub" ]; then
        if ! grep -q "GRUB_DISABLE_OS_PROBER=false" "$mount_point/etc/default/grub"; then
            echo "GRUB_DISABLE_OS_PROBER=false" >> "$mount_point/etc/default/grub"
            chroot "$mount_point" update-grub 2>/dev/null || true
        fi
    fi

    # Cleanup
    for dir in dev/pts dev proc sys boot/efi; do
        umount "$mount_point/$dir" 2>/dev/null || true
    done
    umount "$mount_point" 2>/dev/null || true
    rmdir "$mount_point"

    log_success "GRUB installed on $target_disk"
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
    restore_partition_table "$target_disk" "$backup_path"

    # Get number of partitions
    local partition_count=$(grep PARTITION_COUNT "$backup_path/metadata.txt" | cut -d= -f2)

    # Restore each partition
    for i in $(seq 1 "$partition_count"); do
        local partition_img="$backup_path/partition_${i}.img.gz"

        if [ ! -f "$partition_img" ] && [ ! -f "${partition_img}.type" ]; then
            log_warning "Partition image $partition_img not found, skipping..."
            continue
        fi

        # Get target partition name
        local target_part=$(lsblk -ln -o NAME "/dev/$target_disk" | grep -v "^${target_disk}$" | sed -n "${i}p")

        if [ -z "$target_part" ]; then
            log_error "Could not find partition $i on $target_disk"
            continue
        fi

        restore_partition "/dev/$target_part" "$partition_img"
    done

    # Install bootloader (automatically detects OS type)
    install_bootloader "$target_disk" "$backup_path"

    log_success "=== DISK RESTORE COMPLETED for $target_disk ==="
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

    # Start restore for each disk in parallel
    for disk in "${target_disks[@]}"; do
        (
            restore_to_disk "$backup_path" "$disk"
        ) &
        pids+=($!)

        log_info "Started restore to $disk (PID: ${pids[-1]})"

        # Small delay to avoid I/O congestion
        sleep 1
    done

    # Wait for all restores to complete
    log_info "Waiting for all restore operations to complete..."
    local failed=0

    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            log_success "Restore process $pid completed successfully"
        else
            log_error "Restore process $pid failed"
            ((failed++))
        fi
    done

    if [ $failed -eq 0 ]; then
        log_success "=== ALL DISK RESTORES COMPLETED SUCCESSFULLY ==="
    else
        log_error "=== $failed DISK RESTORE(S) FAILED ==="
        return 1
    fi
}

################################################################################
# INTERACTIVE MENU
################################################################################
show_menu() {
    echo ""
    echo "======================================"
    echo "    CycCloner2000 - Disk Cloning Tool"
    echo "======================================"
    echo ""
    echo "1) Clone disk to files"
    echo "2) Restore to single disk"
    echo "3) Restore to multiple disks (parallel)"
    echo "4) List available disks"
    echo "5) List available backups"
    echo "6) Exit"
    echo ""
}

list_backups() {
    log_info "Available backups in $BACKUP_DIR:"
    if [ -d "$BACKUP_DIR" ]; then
        ls -lh "$BACKUP_DIR" | grep "^d" | awk '{print $9, "("$5")"}'
    else
        log_warning "Backup directory does not exist yet"
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
