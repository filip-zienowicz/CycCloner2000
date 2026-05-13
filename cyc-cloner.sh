#!/bin/bash
set -o pipefail

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/root/images}"
LOG_FILE="${LOG_FILE:-/var/log/cyc-cloner.log}"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
COMPRESSION="${COMPRESSION:-pigz}"  # pigz only for now
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
AUTO_REFRESH_DISKS="${AUTO_REFRESH_DISKS:-true}"
DEVICE_SETTLE_SECONDS="${DEVICE_SETTLE_SECONDS:-2}"
PARTITION_TABLE_SETTLE_SECONDS="${PARTITION_TABLE_SETTLE_SECONDS:-5}"
RANDOMIZE_GPT_GUIDS="${RANDOMIZE_GPT_GUIDS:-false}"
CREATE_EFI_NVRAM_ENTRY="${CREATE_EFI_NVRAM_ENTRY:-false}"
GRUB_BOOTLOADER_ID="${GRUB_BOOTLOADER_ID:-GRUB}"

load_config() {
    local config_files=()
    local config_file

    if [ -n "${CYC_CONFIG:-}" ]; then
        config_files+=("$CYC_CONFIG")
    else
        config_files+=("/etc/cyccloner2000.conf")
        config_files+=("$SCRIPT_DIR/cyccloner.conf")
    fi

    for config_file in "${config_files[@]}"; do
        if [ -f "$config_file" ]; then
            # shellcheck source=/dev/null
            source "$config_file"
        fi
    done
}

load_config

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
    if [ "$AUTO_REFRESH_DISKS" != "true" ]; then
        log_debug "Disk auto-refresh disabled by config"
        return 0
    fi

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
        log_debug "Running partprobe for all block devices..."
        partprobe 2>/dev/null || true
    fi

    # Give kernel time to detect new devices
    sleep "$DEVICE_SETTLE_SECONDS"

    # Trigger udev
    if command -v udevadm &> /dev/null; then
        udevadm trigger --subsystem-match=block 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    log_debug "Disk refresh completed"
}

refresh_disk() {
    local disk=$1
    local disk_path
    disk_path=$(disk_dev "$disk")

    if [ "$AUTO_REFRESH_DISKS" != "true" ]; then
        log_debug "Disk auto-refresh disabled by config"
        return 0
    fi

    log_debug "Refreshing $disk_path..."

    if [ -b "$disk_path" ]; then
        partprobe "$disk_path" 2>/dev/null || true
        blockdev --rereadpt "$disk_path" 2>/dev/null || true
    fi

    if command -v udevadm &> /dev/null; then
        udevadm trigger --subsystem-match=block 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    sleep "$DEVICE_SETTLE_SECONDS"
}

wait_for_partitions() {
    local disk=$1
    local expected_count=${2:-1}
    local attempts=${3:-10}
    local count=0
    local attempt

    for attempt in $(seq 1 "$attempts"); do
        refresh_disk "$disk"
        count=$(list_disk_partitions "$disk" | wc -l | tr -d ' ')

        if [ "$count" -ge "$expected_count" ]; then
            log_debug "Detected $count partition(s) on $(disk_dev "$disk")"
            return 0
        fi

        log_debug "Waiting for partitions on $(disk_dev "$disk") ($count/$expected_count)..."
        sleep 1
    done

    log_warning "Expected $expected_count partition(s) on $(disk_dev "$disk"), detected $count"
    return 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    local deps="awk blkid blockdev dd findmnt lsblk mount partprobe parted pigz sfdisk sgdisk sort tee timeout umount"
    local missing=""

    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            missing="$missing $dep"
        fi
    done

    local partclone_deps="partclone.ext4 partclone.ntfs partclone.vfat"
    for dep in $partclone_deps; do
        if ! command -v "$dep" &> /dev/null; then
            missing="$missing $dep"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Missing dependencies:$missing"
        log_info "Install with: sudo apt-get install parted partclone pigz gdisk util-linux ntfs-3g"
        exit 1
    fi
}

disk_dev() {
    local disk=$1
    if [[ "$disk" == /dev/* ]]; then
        echo "$disk"
    else
        echo "/dev/$disk"
    fi
}

disk_name() {
    basename "$(disk_dev "$1")"
}

partition_number() {
    local partition=$1
    local part_num
    part_num=$(lsblk -npo PARTN "$partition" 2>/dev/null | head -1 | tr -d ' ')

    if [ -n "$part_num" ]; then
        echo "$part_num"
        return 0
    fi

    basename "$partition" | sed -E 's/.*[^0-9]([0-9]+)$/\1/'
}

list_disk_partitions() {
    local disk=$1
    local disk_path
    disk_path=$(disk_dev "$disk")

    lsblk -lnpo NAME,TYPE "$disk_path" 2>/dev/null | awk '$2 == "part" {print $1}'
}

get_metadata_value() {
    local key=$1
    local metadata_file=$2

    [ -f "$metadata_file" ] || return 1
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$metadata_file"
}

get_backup_boot_mode() {
    local backup_path=$1
    local boot_mode
    boot_mode=$(get_metadata_value "BOOT_MODE" "$backup_path/metadata.txt")

    if [ -n "$boot_mode" ]; then
        echo "$boot_mode"
    else
        detect_boot_mode
    fi
}

get_backup_os_type() {
    local backup_path=$1
    local os_type
    os_type=$(get_metadata_value "OS_TYPE" "$backup_path/metadata.txt")

    if [ -n "$os_type" ]; then
        echo "$os_type"
    else
        echo "UNKNOWN"
    fi
}

list_disks() {
    refresh_disk_list
    log_info "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL,SERIAL,TYPE | awk 'NR == 1 || $NF == "disk"'
    echo ""
}

get_disk_info() {
    local disk
    disk=$(disk_name "$1")
    log_info "Disk information for $disk:"
    parted -s "/dev/$disk" print
    lsblk "/dev/$disk" -o NAME,SIZE,FSTYPE,PARTTYPE,PARTUUID,UUID,MOUNTPOINT,LABEL
}

is_disk_mounted() {
    local disk=$1
    local partition

    while read -r partition; do
        [ -n "$partition" ] || continue
        if findmnt -rn -S "$partition" >/dev/null 2>&1; then
            return 0
        fi
    done < <(list_disk_partitions "$disk")

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
    local partition

    while read -r partition; do
        local fs_type
        fs_type=$(get_filesystem_type "$partition")

        # Check if NTFS partition
        if [ "$fs_type" = "ntfs" ]; then
            # Mount temporarily to check for Windows
            local temp_mount="/tmp/cyc-check-${BASHPID:-$$}"
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
    done < <(list_disk_partitions "$disk")

    return 1
}

has_linux_partition() {
    local disk=$1
    local partition

    while read -r partition; do
        local fs_type
        fs_type=$(get_filesystem_type "$partition")

        if [[ "$fs_type" =~ ^ext[2-4]$ ]] || [ "$fs_type" = "xfs" ] || [ "$fs_type" = "btrfs" ]; then
            return 0
        fi
    done < <(list_disk_partitions "$disk")

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
    local partition
    local fallback=""

    while read -r partition; do
        local fs_type part_type
        fs_type=$(get_filesystem_type "$partition")
        part_type=$(lsblk -npo PARTTYPE "$partition" 2>/dev/null | head -1)

        part_type=${part_type,,}

        if [[ "$part_type" =~ ^c12a7328-f81f-11d2-ba4b-00a0c93ec93b$ ]]; then
            echo "$partition"
            return 0
        fi

        if [[ "$fs_type" =~ ^(vfat|fat32|fat16)$ ]] && [ -z "$fallback" ]; then
            fallback="$partition"
        fi
    done < <(list_disk_partitions "$disk")

    [ -n "$fallback" ] && echo "$fallback"
}

find_windows_partition() {
    local disk=$1
    local partition

    while read -r partition; do
        local fs_type
        fs_type=$(get_filesystem_type "$partition")

        if [ "$fs_type" = "ntfs" ]; then
            local temp_mount="/tmp/cyc-check-${BASHPID:-$$}"
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
    done < <(list_disk_partitions "$disk")
}

find_linux_root_partition() {
    local disk=$1
    local partition
    local fallback=""

    while read -r partition; do
        local fs_type
        fs_type=$(get_filesystem_type "$partition")

        if [[ "$fs_type" =~ ^(ext2|ext3|ext4|xfs|btrfs)$ ]]; then
            local temp_mount="/tmp/cyc-linux-check-${BASHPID:-$$}"
            mkdir -p "$temp_mount"

            if timeout 10 mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
                if [ -d "$temp_mount/etc" ] && { [ -d "$temp_mount/boot" ] || [ -d "$temp_mount/usr" ]; }; then
                    umount "$temp_mount"
                    rmdir "$temp_mount"
                    echo "$partition"
                    return 0
                fi
                umount "$temp_mount"
            fi

            rmdir "$temp_mount" 2>/dev/null
        fi
    done < <(list_disk_partitions "$disk")

    # Fallback: choose the largest Linux filesystem partition.
    fallback=$(lsblk -lnbo NAME,FSTYPE,SIZE "$(disk_dev "$disk")" | \
        awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 " /dev/" $1}' | \
        sort -nr | head -1 | awk '{print $2}')

    [ -n "$fallback" ] && echo "$fallback"
}

################################################################################
# PARTITION BACKUP FUNCTIONS
################################################################################
backup_partition_table() {
    local source_disk=$1
    local backup_path=$2
    local source_path
    source_path=$(disk_dev "$source_disk")

    log_info "Backing up partition table for $source_disk..."

    # Backup MBR/GPT
    sgdisk --backup="$backup_path/partition-table.sgdisk" "$source_path" 2>/dev/null
    sfdisk -d "$source_path" > "$backup_path/partition-table.sfdisk" 2>/dev/null

    # Backup MBR boot code (first 446 bytes) for Windows BIOS systems
    dd if="$source_path" of="$backup_path/mbr-backup.bin" bs=446 count=1 2>/dev/null

    # Save disk geometry
    parted -s "$source_path" print > "$backup_path/disk-geometry.txt"

    log_success "Partition table backed up"
}

get_filesystem_type() {
    local partition=$1
    blkid -o value -s TYPE "$partition" 2>/dev/null
}

partclone_command_for_fs() {
    local fs_type=$1

    case "$fs_type" in
        ext2|ext3|ext4)
            echo "partclone.ext4"
            ;;
        ntfs)
            echo "partclone.ntfs"
            ;;
        vfat|fat32|fat16)
            echo "partclone.vfat"
            ;;
        xfs)
            command -v partclone.xfs >/dev/null 2>&1 && echo "partclone.xfs"
            ;;
        btrfs)
            command -v partclone.btrfs >/dev/null 2>&1 && echo "partclone.btrfs"
            ;;
    esac
}

backup_partition() {
    local partition=$1
    local output_file=$2
    local fs_type=$(get_filesystem_type "$partition")
    local partclone_cmd

    log_info "Backing up $partition (filesystem: $fs_type)..."

    # Verify partition exists and is not mounted
    if [ ! -b "$partition" ]; then
        log_error "Partition $partition does not exist"
        return 1
    fi

    case "$fs_type" in
        ext2|ext3|ext4|ntfs|vfat|fat32|fat16|xfs|btrfs)
            partclone_cmd=$(partclone_command_for_fs "$fs_type")
            if [ -n "$partclone_cmd" ]; then
                log_debug "Using $partclone_cmd"
                if ! "$partclone_cmd" -c -s "$partition" 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                    log_error "Failed to backup $partition"
                    return 1
                fi
            else
                log_warning "No partclone command for $fs_type, using dd backup..."
                if ! dd if="$partition" bs=4M status=progress 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                    log_error "Failed to backup $partition with dd"
                    return 1
                fi
            fi
            ;;
        swap)
            log_info "Skipping swap partition $partition"
            echo "swap" > "${output_file}.type"
            echo "swap" > "${output_file}.fstype"
            return 0
            ;;
        "")
            log_warning "No filesystem detected on $partition, using dd backup..."
            if ! dd if="$partition" bs=4M status=progress 2>> "$LOG_FILE" | pigz -c > "$output_file"; then
                log_error "Failed to backup $partition"
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
    local source_disk
    source_disk=$(disk_name "$1")
    local source_path
    source_path=$(disk_dev "$source_disk")

    check_root
    check_dependencies

    log_info "=== STARTING DISK CLONE ==="
    log_info "Source disk: $source_disk"

    refresh_disk_list
    refresh_disk "$source_disk"

    # Verify disk exists
    if [ ! -b "$source_path" ]; then
        log_error "Disk $source_path does not exist"
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
    local partitions
    partitions=$(list_disk_partitions "$source_disk")

    if [ -z "$partitions" ]; then
        log_error "No partitions found on $source_disk"
        return 1
    fi

    local partition_num=1
    local failed=0
    
    for partition in $partitions; do

        # Unmount if mounted
        if findmnt -rn -S "$partition" >/dev/null 2>&1; then
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
SOURCE_SIZE_BYTES=$(blockdev --getsize64 "$source_path" 2>/dev/null || echo 0)
OS_TYPE=$(detect_os_type "$source_disk")
BACKUP_DATE=$(date)
BOOT_MODE=$(detect_boot_mode)
PARTITION_COUNT=$((partition_num - 1))
FAILED_PARTITIONS=$failed
BACKUP_FORMAT_VERSION=2
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
validate_target_capacity() {
    local backup_path=$1
    local target_disk=$2
    local source_size target_size

    source_size=$(get_metadata_value "SOURCE_SIZE_BYTES" "$backup_path/metadata.txt")
    target_size=$(blockdev --getsize64 "$(disk_dev "$target_disk")" 2>/dev/null || echo 0)

    if [ -n "$source_size" ] && [ "$source_size" -gt 0 ] && [ "$target_size" -gt 0 ] && [ "$target_size" -lt "$source_size" ]; then
        log_error "Target disk $(disk_dev "$target_disk") is smaller than source image"
        log_error "Source: $source_size bytes, target: $target_size bytes"
        return 1
    fi

    return 0
}

restore_partition_table() {
    local target_disk
    target_disk=$(disk_name "$1")
    local backup_path=$2
    local target_path
    target_path=$(disk_dev "$target_disk")

    log_info "Restoring partition table to $target_disk..."
    refresh_disk "$target_disk"

    # Wipe existing partition table thoroughly
    log_debug "Wiping existing partition table..."

    # Get disk size in sectors
    local disk_size_sectors=$(blockdev --getsz "$target_path" 2>/dev/null)

    # Wipe with sgdisk (clears GPT)
    sgdisk --zap-all "$target_path" 2>/dev/null || true

    # Wipe beginning of disk (MBR + GPT primary)
    dd if=/dev/zero of="$target_path" bs=1M count=10 2>/dev/null || true

    # Wipe end of disk (GPT backup) if we know disk size
    if [ -n "$disk_size_sectors" ] && [ "$disk_size_sectors" -gt 20480 ]; then
        # Wipe last 10MB where GPT backup resides
        dd if=/dev/zero of="$target_path" bs=1M seek=$((disk_size_sectors / 2048 - 10)) count=10 2>/dev/null || true
    fi

    # Force kernel to re-read empty partition table
    refresh_disk "$target_disk"

    sleep "$PARTITION_TABLE_SETTLE_SECONDS"

    # Restore GPT
    if [ -f "$backup_path/partition-table.sgdisk" ]; then
        log_debug "Restoring GPT partition table..."
        if sgdisk --load-backup="$backup_path/partition-table.sgdisk" "$target_path" 2>&1 | tee -a "$LOG_FILE"; then
            if [ "$RANDOMIZE_GPT_GUIDS" = "true" ]; then
                log_warning "Randomizing GPT GUIDs because RANDOMIZE_GPT_GUIDS=true"
                sgdisk -G "$target_path"
            else
                log_info "Preserving GPT GUIDs for boot compatibility"
            fi
            log_success "GPT partition table restored"
        else
            log_warning "Failed to restore GPT, trying sfdisk..."
            if [ -f "$backup_path/partition-table.sfdisk" ]; then
                sfdisk "$target_path" < "$backup_path/partition-table.sfdisk" 2>&1 | tee -a "$LOG_FILE"
            fi
        fi
    elif [ -f "$backup_path/partition-table.sfdisk" ]; then
        log_debug "Restoring partition table with sfdisk..."
        sfdisk "$target_path" < "$backup_path/partition-table.sfdisk" 2>&1 | tee -a "$LOG_FILE"
    else
        log_error "No partition table backup found"
        return 1
    fi

    # Inform kernel of partition changes
    log_debug "Informing kernel of partition changes..."
    refresh_disk "$target_disk"
    sleep "$PARTITION_TABLE_SETTLE_SECONDS"

    log_success "Partition table restored"
    return 0
}

restore_partition() {
    local partition=$1
    local input_file=$2
    local fs_type=""
    local partclone_cmd

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
        ext2|ext3|ext4|ntfs|vfat|fat32|fat16|xfs|btrfs)
            partclone_cmd=$(partclone_command_for_fs "$fs_type")
            if [ -n "$partclone_cmd" ]; then
                log_debug "Command: pigz -dc $input_file | $partclone_cmd -r -d -o $partition"
                if pigz -dc "$input_file" | "$partclone_cmd" -r -d -o "$partition" 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Successfully restored $fs_type partition"
                else
                    log_error "Failed to restore $fs_type partition"
                    return 1
                fi
            else
                log_info "No partclone command for $fs_type, using dd restore..."
                if pigz -dc "$input_file" | dd of="$partition" bs=4M status=progress 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Successfully restored with dd"
                else
                    log_error "Failed to restore with dd"
                    return 1
                fi
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
    local target_disk
    target_disk=$(disk_name "$1")
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
    local efi_mount="/mnt/cyc-efi-${target_disk}-${BASHPID:-$$}"
    mkdir -p "$efi_mount"
    
    if ! timeout 10 mount "$efi_part" "$efi_mount" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to mount EFI partition"
        rmdir "$efi_mount"
        return 1
    fi

    local win_mount="/mnt/cyc-win-${target_disk}-${BASHPID:-$$}"
    local win_mounted=false

    if [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        log_info "Windows bootloader already exists in EFI partition"
    else
        # Mount Windows partition only when the EFI copy needs to be rebuilt.
        mkdir -p "$win_mount"

        if ! timeout 10 mount -t ntfs-3g -o ro "$win_part" "$win_mount" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to mount Windows partition"
            umount "$efi_mount" 2>/dev/null
            rmdir "$efi_mount" "$win_mount"
            return 1
        fi
        win_mounted=true

        if [ -d "$win_mount/Windows/Boot" ]; then
            log_info "Found Windows Boot Manager, copying to EFI partition..."

            mkdir -p "$efi_mount/EFI/Microsoft/Boot"

            if [ -d "$win_mount/Windows/Boot/EFI" ]; then
                cp -r "$win_mount/Windows/Boot/EFI/"* "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | tee -a "$LOG_FILE" || true
            fi

            if [ -f "$win_mount/Boot/BCD" ]; then
                cp "$win_mount/Boot/BCD" "$efi_mount/EFI/Microsoft/Boot/" 2>&1 | tee -a "$LOG_FILE" || true
            fi
        else
            log_warning "Could not find Windows Boot Manager files"
        fi
    fi

    # Install the removable UEFI fallback path. This travels with the disk.
    if [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        mkdir -p "$efi_mount/EFI/BOOT"
        cp "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" "$efi_mount/EFI/BOOT/BOOTX64.EFI" 2>&1 | tee -a "$LOG_FILE" || true
        log_success "Windows UEFI fallback installed at EFI/BOOT/BOOTX64.EFI"
    else
        log_error "Windows bootmgfw.efi missing after repair attempt"
        umount "$win_mount" 2>/dev/null
        umount "$efi_mount" 2>/dev/null
        rmdir "$win_mount" "$efi_mount" 2>/dev/null || true
        return 1
    fi

    # Optional: useful only when this cloned disk should boot in the current host.
    if [ "$CREATE_EFI_NVRAM_ENTRY" = "true" ] && command -v efibootmgr >/dev/null 2>&1; then
        local efi_part_num
        efi_part_num=$(partition_number "$efi_part")

        log_debug "Creating EFI NVRAM boot entry on this host..."
        efibootmgr -c -d "/dev/$target_disk" -p "$efi_part_num" \
                   -L "Windows Boot Manager" \
                   -l "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" 2>&1 | tee -a "$LOG_FILE" || {
            log_warning "Could not create EFI boot entry"
        }
    fi

    # Cleanup
    sync
    if [ "$win_mounted" = "true" ]; then
        umount "$win_mount" 2>/dev/null
    fi
    umount "$efi_mount" 2>/dev/null
    rmdir "$win_mount" "$efi_mount" 2>/dev/null || true

    log_success "Windows UEFI bootloader installed"
    return 0
}

install_windows_bootloader_bios() {
    local target_disk
    target_disk=$(disk_name "$1")
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
    local target_disk
    target_disk=$(disk_name "$1")
    local backup_path=$2
    local boot_mode
    boot_mode=$(get_backup_boot_mode "$backup_path")
    local grub_failed=0

    log_info "Installing GRUB on $target_disk (boot mode: $boot_mode)..."

    if ! command -v grub-install >/dev/null 2>&1; then
        log_error "grub-install not found. Install GRUB tools for the cloned OS type."
        return 1
    fi

    # Mount partitions temporarily
    local mount_point="/mnt/cyc-cloner-${target_disk}-${BASHPID:-$$}"
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

    # Enable Windows discovery before generating GRUB config on mixed images.
    if [ -f "$mount_point/etc/default/grub" ]; then
        if grep -q "^#*GRUB_DISABLE_OS_PROBER=" "$mount_point/etc/default/grub"; then
            sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$mount_point/etc/default/grub"
        else
            echo "GRUB_DISABLE_OS_PROBER=false" >> "$mount_point/etc/default/grub"
        fi
    fi

    # Install GRUB
    if [ "$boot_mode" = "UEFI" ]; then
        log_debug "Installing GRUB for UEFI..."
        chroot "$mount_point" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$GRUB_BOOTLOADER_ID" --no-nvram --removable --recheck "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || {
            log_warning "UEFI GRUB installation failed, trying without chroot..."
            grub-install --target=x86_64-efi --boot-directory="$mount_point/boot" --efi-directory="$mount_point/boot/efi" --bootloader-id="$GRUB_BOOTLOADER_ID" --no-nvram --removable --recheck "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || grub_failed=1
        }
    else
        log_debug "Installing GRUB for BIOS..."
        chroot "$mount_point" grub-install "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || {
            log_warning "BIOS GRUB installation failed, trying without chroot..."
            grub-install --boot-directory="$mount_point/boot" "/dev/$target_disk" 2>&1 | tee -a "$LOG_FILE" || grub_failed=1
        }
    fi

    # Update GRUB configuration (will detect Windows if present)
    log_debug "Updating GRUB configuration..."
    chroot "$mount_point" update-grub 2>&1 | tee -a "$LOG_FILE" || {
        chroot "$mount_point" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$LOG_FILE" || true
    }

    # Cleanup
    sync
    for dir in dev/pts dev proc sys boot/efi; do
        umount "$mount_point/$dir" 2>/dev/null || true
    done
    umount "$mount_point" 2>/dev/null || true
    rmdir "$mount_point"

    if [ $grub_failed -ne 0 ]; then
        log_error "GRUB installation failed on $target_disk"
        return 1
    fi

    log_success "GRUB installed on $target_disk"
    return 0
}

################################################################################
# SMART BOOTLOADER INSTALLATION
################################################################################
install_bootloader() {
    local target_disk
    target_disk=$(disk_name "$1")
    local backup_path=$2
    local failed=0

    log_info "Detecting OS type on $target_disk..."
    local os_type
    os_type=$(get_backup_os_type "$backup_path")
    if [ "$os_type" = "UNKNOWN" ]; then
        os_type=$(detect_os_type "$target_disk")
    fi
    local boot_mode
    boot_mode=$(get_backup_boot_mode "$backup_path")

    log_info "Detected OS type: $os_type"
    log_info "Boot mode: $boot_mode"

    case "$os_type" in
        WINDOWS)
            log_info "Installing Windows-only bootloader..."
            if [ "$boot_mode" = "UEFI" ]; then
                install_windows_bootloader_uefi "$target_disk" "$backup_path" || failed=1
            else
                install_windows_bootloader_bios "$target_disk" "$backup_path" || failed=1
            fi
            ;;
        LINUX)
            log_info "Installing Linux-only bootloader (GRUB)..."
            install_grub "$target_disk" "$backup_path" || failed=1
            ;;
        MIXED)
            log_info "Installing bootloader for dual-boot system..."
            # For mixed systems, install GRUB which will detect Windows
            install_grub "$target_disk" "$backup_path" || failed=1
            # Also ensure Windows bootloader is present in EFI partition
            if [ "$boot_mode" = "UEFI" ]; then
                install_windows_bootloader_uefi "$target_disk" "$backup_path" || failed=1
            fi
            ;;
        *)
            log_warning "Could not detect OS type, attempting GRUB installation..."
            install_grub "$target_disk" "$backup_path" || failed=1
            ;;
    esac

    return $failed
}

restore_to_disk() {
    local backup_path=$1
    local target_disk
    target_disk=$(disk_name "$2")
    local target_path
    target_path=$(disk_dev "$target_disk")

    log_info "=== STARTING DISK RESTORE ==="
    log_info "Source: $backup_path"
    log_info "Target: $target_disk"

    refresh_disk_list
    refresh_disk "$target_disk"

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
    if [ ! -b "$target_path" ]; then
        log_error "Target disk $target_path does not exist"
        return 1
    fi

    if ! validate_target_capacity "$backup_path" "$target_disk"; then
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
    local target_partitions
    wait_for_partitions "$target_disk" "$partition_count" 12 || true
    target_partitions=$(list_disk_partitions "$target_disk")

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
        local target_part
        target_part=$(printf '%s\n' "$target_partitions" | sed -n "${i}p")

        if [ -z "$target_part" ]; then
            log_error "Could not find partition $i on $target_disk"
            ((failed++))
            continue
        fi

        log_info "Restoring partition $i/$partition_count to $target_part..."
        
        if ! restore_partition "$target_part" "$partition_img"; then
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
    if ! install_bootloader "$target_disk" "$backup_path"; then
        log_error "Bootloader installation failed for $target_disk"
        return 1
    fi

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
    local target_disks=()
    local disk

    for disk in "$@"; do
        target_disks+=("$(disk_name "$disk")")
    done

    log_info "=== STARTING PARALLEL MULTI-DISK RESTORE ==="
    log_info "Source: $backup_path"
    log_info "Targets: ${target_disks[*]}"
    log_info "Parallel jobs: ${#target_disks[@]}"

    refresh_disk_list

    if [ ${#target_disks[@]} -eq 0 ]; then
        log_error "No target disks specified"
        return 1
    fi

    # Create array to store PIDs
    local pids=()
    local seen=" "

    for disk in "${target_disks[@]}"; do
        if [[ "$seen" == *" $disk "* ]]; then
            log_error "Duplicate target disk specified: $disk"
            return 1
        fi
        seen="$seen$disk "
    done

    # Start restore for each disk in parallel
    for disk in "${target_disks[@]}"; do
        (
            # Create separate log for this disk
            local disk_log="/tmp/cyc-clone-${disk}-${BASHPID:-$$}.log"
            
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

resolve_backup_path() {
    local backup=$1

    if [ -d "$backup" ]; then
        echo "$backup"
    else
        echo "$BACKUP_DIR/$backup"
    fi
}

usage() {
    cat << EOF
CycCloner2000

Usage:
  $0 menu
  $0 clone <source-disk>
  $0 restore <backup-name-or-path> <target-disk>
  $0 restore-many <backup-name-or-path> <target-disk> [target-disk...]
  $0 list-disks
  $0 list-backups

Examples:
  $0 clone sda
  $0 restore sda_20260513_120000 sdb
  $0 restore-many sda_20260513_120000 sdb sdc sdd sde sdf

Environment:
  CYC_CONFIG=/path/to/conf         load an explicit config file
  RANDOMIZE_GPT_GUIDS=true        randomize GPT disk/partition GUIDs after restore
  CREATE_EFI_NVRAM_ENTRY=true     create EFI NVRAM entry on this host
  GRUB_BOOTLOADER_ID=GRUB         UEFI GRUB bootloader id

Config files:
  /etc/cyccloner2000.conf
  $SCRIPT_DIR/cyccloner.conf
EOF
}

################################################################################
# MAIN
################################################################################
main() {
    if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        return 0
    fi

    check_root
    check_dependencies

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Create log file if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    log_info "CycCloner2000 started"
    log_info "Log file: $LOG_FILE"

    if [ $# -gt 0 ]; then
        local command=$1
        shift

        case "$command" in
            menu)
                ;;
            clone)
                if [ $# -ne 1 ]; then
                    usage
                    return 1
                fi
                clone_disk_to_files "$1"
                return $?
                ;;
            restore)
                if [ $# -ne 2 ]; then
                    usage
                    return 1
                fi
                restore_to_disk "$(resolve_backup_path "$1")" "$2"
                return $?
                ;;
            restore-many|restore-multiple)
                if [ $# -lt 2 ]; then
                    usage
                    return 1
                fi
                local backup_path
                backup_path=$(resolve_backup_path "$1")
                shift
                restore_to_multiple_disks "$backup_path" "$@"
                return $?
                ;;
            list-disks)
                list_disks
                return $?
                ;;
            list-backups)
                list_backups
                return $?
                ;;
            *)
                usage
                return 1
                ;;
        esac
    fi

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
