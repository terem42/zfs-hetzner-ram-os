#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Ubuntu 24 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -euo pipefail

# ---- Configuration ----
# These will be set by user input
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
ZFS_ARC_SIZE=""
UBUNTU_CODENAME="noble"   # Ubuntu 24.04
TARGET="/mnt/ubuntu"
REPLICATED_STORAGE_SIZE="10G"       # Default replicated storage partition size

ZBM_BIOS_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.tar.gz"
ZBM_EFI_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.EFI"

MAIN_BOOT="/main_boot"

# Hetzner mirrors
MIRROR_SITE="https://mirror.hetzner.com"
MIRROR_MAIN="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME} main restricted universe multiverse"
MIRROR_UPDATES="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-updates main restricted universe multiverse"
MIRROR_BACKPORTS="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-backports main restricted universe multiverse"
MIRROR_SECURITY="deb ${MIRROR_SITE}/ubuntu/security ${UBUNTU_CODENAME}-security main restricted universe multiverse"

# Global variables
INSTALL_DISK=""
EFI_MODE=false
BOOT_LABEL=""
BOOT_TYPE=""
BOOT_PART=""
ZFS_PART=""
REPLICATED_STORAGE_PART=""
DISK_SIZE=""

# ---- User Input Functions ----
function setup_whiptail_colors {
    # Green text on black background - classic terminal theme
    export NEWT_COLORS='
    root=green,black
    window=green,black
    shadow=green,black
    border=green,black
    title=green,black
    textbox=green,black
    button=black,green
    listbox=green,black
    actlistbox=black,green
    actsellistbox=black,green
    checkbox=green,black
    actcheckbox=black,green
    entry=green,black
    label=green,black
    '
}

function check_whiptail {
    if ! command -v whiptail &> /dev/null; then
        echo "Installing whiptail..."
        apt update
        apt install -y whiptail
    fi
    setup_whiptail_colors
}

function get_disk_info {
    echo "======= Analyzing Disk Capacity =========="
    
    # Get disk size in human-readable format and bytes
    DISK_SIZE=$(lsblk -b -n -o SIZE "$INSTALL_DISK" | head -1)
    DISK_SIZE_HR=$(lsblk -n -o SIZE "$INSTALL_DISK" | head -1)
    
    echo "Installation disk: $INSTALL_DISK"
    echo "Total capacity: $DISK_SIZE_HR ($DISK_SIZE bytes)"
}

function get_replicated_storage_size {
    echo "======= Configuring replicated storage Partition Size =========="
    
    # Calculate available space for ZFS after boot partition (128MB)
    local boot_size_bytes=134217728  # 128MB in bytes
    local available_bytes=$((DISK_SIZE - boot_size_bytes))
    local available_gb=$((available_bytes / 1024 / 1024 / 1024))
    
    # Calculate default replicated size in GB (10GB default)
    local default_replicated_storage_gb=10
    local max_replicated_storage_gb=$((available_gb - 1))  # Leave at least 1GB for ZFS
    
    if [ $max_replicated_storage_gb -lt $default_replicated_storage_gb ]; then
        default_replicated_storage_gb=$max_replicated_storage_gb
    fi
    
    while true; do
        REPLICATED_STORAGE_SIZE=$(whiptail \
            --title "Replicated storage Partition Size" \
            --inputbox "Total disk capacity: $DISK_SIZE_HR\n\nHow much space to reserve for replicated storage (unformatted raw partition)?\n\nAvailable: 0GB - ${max_replicated_storage_gb}GB\nRecommended: 10GB or more for testing\n\nEnter size with unit (G for GB, M for MB) (enter 0 to disable):" \
            16 70 "${default_replicated_storage_gb}G" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Validate the size format and range
        if [[ "$REPLICATED_STORAGE_SIZE" =~ ^[0-9]+[MG]$ ]]; then
            local size_num=${REPLICATED_STORAGE_SIZE%[MG]}
            local size_unit=${REPLICATED_STORAGE_SIZE: -1}
            
            if [ "$size_unit" = "G" ]; then
                local size_gb=$size_num
            else
                # Convert MB to GB
                local size_gb=$((size_num / 1024))
                if [ $size_gb -eq 0 ]; then
                    size_gb=1
                fi
            fi
            
            if [ $size_gb -ge 0 ] && [ $size_gb -le $max_replicated_storage_gb ]; then
                break
            else
                whiptail \
                    --title "Invalid Size" \
                    --msgbox "Size must be between 0GB and ${max_replicated_storage_gb}GB. You entered: ${REPLICATED_STORAGE_SIZE}" \
                    12 60
            fi
        else
            whiptail \
                --title "Invalid Format" \
                --msgbox "Please enter size in format like '10G' for 10GB or '512M' for 512MB." \
                12 60
        fi
    done
    
    echo "Replicated storage partition size set to: $REPLICATED_STORAGE_SIZE"
}

function get_hostname {
    while true; do
        SYSTEM_HOSTNAME=$(whiptail \
            --title "System Hostname" \
            --inputbox "Enter the hostname for the new system:" \
            10 60 "zfs-ubuntu" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
            break
        else
            whiptail \
                --title "Invalid Hostname" \
                --msgbox "Invalid hostname. Please use only letters, numbers, and hyphens. Must start and end with alphanumeric character. Maximum 63 characters." \
                12 60
        fi
    done
}

function get_zfs_pool_name {
    while true; do
        ZFS_POOL=$(whiptail \
            --title "ZFS Pool Name" \
            --inputbox "Enter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Validate ZFS pool name
        if [[ "$ZFS_POOL" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] && [[ ${#ZFS_POOL} -le 255 ]]; then
            break
        else
            whiptail \
                --title "Invalid Pool Name" \
                --msgbox "Invalid ZFS pool name. Must start with a letter and contain only letters, numbers, hyphens, and underscores. Maximum 255 characters." \
                12 60
        fi
    done
}

function get_zfs_arc_size {
    echo "======= Configuring ZFS ARC Cache Size =========="
    
    # Calculate recommended ARC size based on available memory (1/8 of total RAM or 500MB min)
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    local recommended_arc=$((total_ram_mb / 8))
    
    # Set minimum recommended ARC to 500MB
    if [ $recommended_arc -lt 500 ]; then
        recommended_arc=500
    fi
    
    # Set maximum reasonable ARC to 1/4 of total RAM
    local max_reasonable_arc=$((total_ram_mb / 4))
    
    while true; do
        ZFS_ARC_SIZE=$(whiptail \
            --title "ZFS ARC Cache Size" \
            --inputbox "Configure ZFS ARC (Adaptive Replacement Cache) size.\n\nTotal system RAM: ${total_ram_mb}MB\nRecommended: ${recommended_arc}MB (1/8 of RAM)\nMaximum reasonable: ${max_reasonable_arc}MB (1/4 of RAM)\n\nEnter ARC size in MB (leave empty for 500MB, 0 to disable limit):" \
            16 70 "500" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Handle empty input (use default)
        if [ -z "$ZFS_ARC_SIZE" ]; then
            ZFS_ARC_SIZE="500"
            echo "Using default ARC size: 500MB"
            break
        fi
        
        # Handle "0" to disable limit
        if [ "$ZFS_ARC_SIZE" = "0" ]; then
            echo "ZFS ARC cache limit disabled (will use default ZFS behavior)"
            break
        fi
        
        # Validate the input is a positive number
        if [[ "$ZFS_ARC_SIZE" =~ ^[0-9]+$ ]]; then
            if [ "$ZFS_ARC_SIZE" -ge 64 ] && [ "$ZFS_ARC_SIZE" -le 1048576 ]; then  # 64MB to 1TB reasonable range
                break
            else
                whiptail \
                    --title "Invalid Size" \
                    --msgbox "Please enter a size between 64MB and 1048576MB (1TB). You entered: ${ZFS_ARC_SIZE}MB" \
                    12 60
            fi
        else
            whiptail \
                --title "Invalid Format" \
                --msgbox "Please enter a number in MB (like '500' for 500MB), '0' to disable limit, or leave empty for default 500MB." \
                12 60
        fi
    done
    
    echo "ZFS ARC cache size set to: ${ZFS_ARC_SIZE}MB"
}

function get_root_password {
    while true; do
        # Get first password input
        local password1
        local password2
        
        password1=$(whiptail \
            --title "Root Password" \
            --passwordbox "Enter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Get password confirmation
        password2=$(whiptail \
            --title "Confirm Root Password" \
            --passwordbox "Confirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Check if passwords match
        if [ "$password1" = "$password2" ]; then
            if [ -n "$password1" ]; then
                ROOT_PASSWORD="$password1"
                break
            else
                whiptail \
                    --title "Empty Password" \
                    --msgbox "Password cannot be empty. Please enter a password." \
                    10 50
            fi
        else
            whiptail \
                --title "Password Mismatch" \
                --msgbox "Passwords do not match. Please try again." \
                10 50
        fi
    done
}

function show_summary_and_confirm {
    # Calculate partition sizes for display
    local boot_size="128MB"
    local replicated_storage_size="$REPLICATED_STORAGE_SIZE"
    
    local replicated_storage_info=""
    if [ "$REPLICATED_STORAGE_SIZE" = "0G" ]; then
        replicated_storage_info="No replicated storage partition"
    else
        replicated_storage_info="Replicated storage: $replicated_storage_size (raw)"
    fi
    
    local arc_info=""
    if [ "$ZFS_ARC_SIZE" = "0" ]; then
        arc_info="ZFS ARC: Default (no limit)"
    else
        arc_info="ZFS ARC: ${ZFS_ARC_SIZE}MB"
    fi
    
    # Get disk information for display
    get_disk_info
    
    # Calculate estimated ZFS partition size
    local zfs_size_gb=""
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        # Extract numeric value from REPLICATED_STORAGE_SIZE (e.g., "10G" -> 10)
        local replicated_storage_num=${REPLICATED_STORAGE_SIZE%[MG]}
        if [[ "$REPLICATED_STORAGE_SIZE" =~ M$ ]]; then
            # Convert MB to GB
            local replicated_storage_gb=$((replicated_storage_num / 1024))
            [ $replicated_storage_gb -eq 0 ] && replicated_storage_gb=1
        else
            local replicated_storage_gb=$replicated_storage_num
        fi
        
        # Extract numeric disk size (e.g., "38.1G" -> 38.1)
        local disk_size_num=$(echo "$DISK_SIZE_HR" | grep -oE '[0-9]+\.?[0-9]*')
        local disk_size_unit=$(echo "$DISK_SIZE_HR" | grep -oE '[GT]B?')
        
        # Calculate ZFS size (total disk - boot - replicated storage)
        if [[ "$disk_size_unit" =~ G ]]; then
            local zfs_gb=$(echo "$disk_size_num - 0.128 - $replicated_storage_gb" | bc -l 2>/dev/null || echo "$disk_size_num")
            zfs_size_gb=$(printf "%.1fG" "$zfs_gb")
        else
            # If disk is in TB, convert to GB for calculation
            local disk_gb=$(echo "$disk_size_num * 1024" | bc -l 2>/dev/null || echo "0")
            local zfs_gb=$(echo "$disk_gb - 0.128 - $replicated_storage_gb" | bc -l 2>/dev/null || echo "$disk_gb")
            zfs_size_gb=$(printf "%.1fG" "$zfs_gb")
        fi
    else
        # No replicated storage partition - ZFS gets everything after boot
        local disk_size_num=$(echo "$DISK_SIZE_HR" | grep -oE '[0-9]+\.?[0-9]*')
        local disk_size_unit=$(echo "$DISK_SIZE_HR" | grep -oE '[GT]B?')
        
        if [[ "$disk_size_unit" =~ G ]]; then
            local zfs_gb=$(echo "$disk_size_num - 0.128" | bc -l 2>/dev/null || echo "$disk_size_num")
            zfs_size_gb=$(printf "%.1fG" "$zfs_gb")
        else
            # If disk is in TB, convert to GB for calculation
            local disk_gb=$(echo "$disk_size_num * 1024" | bc -l 2>/dev/null || echo "0")
            local zfs_gb=$(echo "$disk_gb - 0.128" | bc -l 2>/dev/null || echo "$disk_gb")
            zfs_size_gb=$(printf "%.1fG" "$zfs_gb")
        fi
    fi
    
    # Fallback if calculation failed
    if [ -z "$zfs_size_gb" ] || [[ ! "$zfs_size_gb" =~ G$ ]]; then
        if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
            zfs_size_gb="Remaining (~$(echo "$DISK_SIZE_HR" | sed 's/[GT]B//' | awk -v replicated="${REPLICATED_STORAGE_SIZE%G}" '{print $1 - 0.128 - replicated}')G)"
        else
            zfs_size_gb="Remaining (~$(echo "$DISK_SIZE_HR" | sed 's/[GT]B//' | awk '{print $1 - 0.128}')G)"
        fi
    fi
    
    local summary="Please review the installation settings:

System Configuration:
├── Hostname: $SYSTEM_HOSTNAME
├── ZFS Pool: $ZFS_POOL
├── Ubuntu Version: $UBUNTU_CODENAME (24.04)
├── Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")
├── $arc_info

Disk Layout:
├── Install Disk: $INSTALL_DISK ($DISK_SIZE_HR)
├── Boot Partition: $boot_size
├── ZFS Pool: $zfs_size_gb
└── $replicated_storage_info

*** WARNING: This will DESTROY ALL DATA on $INSTALL_DISK! ***

Do you want to continue with the installation?"
    
    if whiptail \
        --title " Installation Summary " \
        --yesno "$summary" \
        22 75; then
        # User confirmed - just continue silently
        echo "User confirmed installation. Starting now..."
    else
        echo "Installation cancelled by user."
        exit 1
    fi
}

function get_user_input {
    echo "======= Gathering Installation Parameters =========="
    check_whiptail
    
    # Show welcome message
    whiptail \
        --title "ZFS Ubuntu Installer" \
        --msgbox "Welcome to the ZFS Ubuntu Installer for Hetzner Cloud.\n\nThis script will install Ubuntu 24.04 with ZFS root on your server.\n\nYou will have the option to create a raw partition for replicated storage and configure ZFS ARC cache size." \
        12 60
    
    # Get user inputs
    get_hostname
    get_zfs_pool_name
    get_root_password
    get_zfs_arc_size
}

# ---- System Detection Functions ----
function detect_efi {
    # Self-repair: Ensure /dev/fd exists for process substitution
    if [ ! -e /dev/fd ]; then
        echo "Creating missing /dev/fd symlink..."
        ln -s /proc/self/fd /dev/fd 2>/dev/null || true
    fi

    echo "======= Detecting EFI support =========="
    
    if [ -d /sys/firmware/efi ]; then
        echo "✓ EFI firmware detected"
        EFI_MODE=true
        BOOT_LABEL="EFI"
        BOOT_TYPE="ef00"
    else
        echo "✓ Legacy BIOS mode detected"
        EFI_MODE=false
        BOOT_LABEL="boot"
        BOOT_TYPE="8300"
    fi
}

function find_install_disk {
    echo "======= Finding install disk =========="
    
    local candidate_disks=()
    
    # Use lsblk to find all unmounted, writable disks
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && candidate_disks+=("$disk")
    done < <(lsblk -npo NAME,TYPE,RO,MOUNTPOINT | awk '
        $2 == "disk" && $3 == "0" && $4 == "" {print $1}
    ')
    
    if [[ ${#candidate_disks[@]} -eq 0 ]]; then
        echo "No suitable installation disks found" >&2
        echo "Looking for: unmounted, writable disks without partitions in use" >&2
        exit 1
    fi
    
    INSTALL_DISK="${candidate_disks[0]}"
    echo "Using installation disk: $INSTALL_DISK"
    
    # Show all available disks for verification
    echo "All available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,RO | grep -v loop
    
    # Get disk information for partitioning decisions
    get_disk_info
    get_replicated_storage_size
}

# ---- Rescue System Preparation Functions ----
function remove_unused_kernels {
    echo "=========== Removing unused kernels in rescue system =========="
    for kver in $(find /lib/modules/* -maxdepth 0 -type d \
                    | grep -v "$(uname -r)" \
                    | cut -s -d "/" -f 4); do

        for pkg in "linux-headers-$kver" "linux-image-$kver"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                echo "Purging $pkg ..."
                apt purge --yes "$pkg"
            else
                echo "Package $pkg not installed, skipping."
            fi
        done
    done
}



# ---- Disk Partitioning Functions ----
function partition_disk {
    echo "======= Partitioning disk =========="
    
    # Show partitioning plan
    echo "Partition layout:"
    echo "1. Boot: 128MB"
    echo "2. ZFS: Remaining space"
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        echo "3. Replicated storage: $REPLICATED_STORAGE_SIZE (raw, unformatted)"
    fi
    
    # Wipe just the partition table (keep it simple)
    echo "Wiping partition table on $INSTALL_DISK..."
    sgdisk -Z "$INSTALL_DISK"
    
    # Create partitions based on mode and replicated storage choice
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        # With replicates storage partition
        if [ "$EFI_MODE" = true ]; then
            echo "Creating EFI partition layout with replicated storage"
            # EFI System Partition (ESP) - 128MB
            sgdisk -n1:1M:+128M -t1:ef00 -c1:"EFI" "$INSTALL_DISK"
            # ZFS partition (remaining space minus replicated storage size)
            sgdisk -n2:0:-$REPLICATED_STORAGE_SIZE -t2:bf00 -c2:"zfs" "$INSTALL_DISK"
            # replicated storage raw partition
            sgdisk -n3:0:0 -t3:8300 -c3:"replicated" "$INSTALL_DISK"
        else
            echo "Creating BIOS partition layout with replicated storage"
            # /boot partition - 128MB
            sgdisk -n1:1M:+128M -t1:8300 -c1:"boot" "$INSTALL_DISK"
            # ZFS partition (remaining space minus replicated storage size)
            sgdisk -n2:0:-$REPLICATED_STORAGE_SIZE -t2:bf00 -c2:"zfs" "$INSTALL_DISK"
            # replicated storage raw partition
            sgdisk -n3:0:0 -t3:8300 -c3:"replicated" "$INSTALL_DISK"
            # Set legacy BIOS bootable flag
            sgdisk -A 1:set:2 "$INSTALL_DISK"
        fi
    else
        # Without replicated storage partition - use entire disk for ZFS after boot
        if [ "$EFI_MODE" = true ]; then
            echo "Creating EFI partition layout without replicated storage"
            sgdisk -n1:1M:+128M -t1:ef00 -c1:"EFI" "$INSTALL_DISK"
            sgdisk -n2:0:0 -t2:bf00 -c2:"zfs" "$INSTALL_DISK"
        else
            echo "Creating BIOS partition layout without replicated storage"
            sgdisk -n1:1M:+128M -t1:8300 -c1:"boot" "$INSTALL_DISK"
            sgdisk -n2:0:0 -t2:bf00 -c2:"zfs" "$INSTALL_DISK"
            sgdisk -A 1:set:2 "$INSTALL_DISK"
        fi
    fi
    
    # Force kernel to reread partition table
    echo "Reloading partition table..."
    partprobe "$INSTALL_DISK" || true
    udevadm settle
    sleep 3  # Give more time for partitions to appear
    
    # VERIFY PARTITIONS EXIST AND ARE CORRECT
    echo "Verifying created partitions..."
    
    # Detect partitions by PARTLABEL with retries
    local retries=5
    local wait_time=2
    
    while [ $retries -gt 0 ]; do
        if [ "$EFI_MODE" = true ]; then
            BOOT_PART="$(blkid -t PARTLABEL='EFI' -o device)"
            ZFS_PART="$(blkid -t PARTLABEL='zfs' -o device)"
            if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
                REPLICATED_STORAGE_PART="$(blkid -t PARTLABEL='replicated' -o device)"
            fi
        else
            BOOT_PART="$(blkid -t PARTLABEL='boot' -o device)"
            ZFS_PART="$(blkid -t PARTLABEL='zfs' -o device)"
            if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
                REPLICATED_STORAGE_PART="$(blkid -t PARTLABEL='replicated' -o device)"
            fi
        fi
        
        # Check if all required partitions are detected
        if [ -n "$BOOT_PART" ] && [ -n "$ZFS_PART" ] && \
           { [ "$REPLICATED_STORAGE_SIZE" = "0G" ] || [ -n "$REPLICATED_STORAGE_PART" ]; }; then
            break
        fi
        
        echo "Partitions not fully detected yet, retrying in ${wait_time}s... ($retries retries left)"
        sleep $wait_time
        udevadm settle
        ((retries--))
    done
    
    # Verify we got the right devices
    echo "Detected partitions:"
    echo "Boot: $BOOT_PART"
    echo "ZFS: $ZFS_PART"
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        echo "Replicated storage: $REPLICATED_STORAGE_PART"
    else
        echo "Replicated storage: disabled"
    fi
    
    # Validate partition devices
    if [ -z "$BOOT_PART" ] || [ ! -b "$BOOT_PART" ]; then
        echo "ERROR: Boot partition not found or not a block device!"
        echo "Available partitions:"
        blkid | grep "$INSTALL_DISK"
        exit 1
    fi
    
    if [ -z "$ZFS_PART" ] || [ ! -b "$ZFS_PART" ]; then
        echo "ERROR: ZFS partition not found or not a block device!"
        echo "Available partitions:"
        blkid | grep "$INSTALL_DISK"
        exit 1
    fi
    
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ] && ([ -z "$REPLICATED_STORAGE_PART" ] || [ ! -b "$REPLICATED_STORAGE_PART" ]); then
        echo "ERROR: Replicated storage partition not found or not a block device!"
        echo "Available partitions:"
        blkid | grep "$INSTALL_DISK"
        exit 1
    fi
    
    # Wipe partitions to remove any existing signatures
    echo "Wiping partition headers to ensure clean slate..."
    
    # Wipe ZFS partition (first 1MB to remove any existing signatures)
    echo "Wiping first 1MB of ZFS partition..."
    dd if=/dev/zero of="$ZFS_PART" bs=1M count=1 status=progress 2>/dev/null || true
    sync
    echo "✓ ZFS partition wiped"
    
    # Wipe replicated storage partition if present
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        echo "Wiping replicated storage partition..."
        dd if=/dev/zero of="$REPLICATED_STORAGE_PART" bs=1M count=1 status=progress 2>/dev/null || true
        sync
        echo "✓ Replicated storage partition wiped"
    fi
    
    # Boot partition doesn't need wiping since we format it fresh
    
    # Format boot partitions
    if [ "$EFI_MODE" = true ]; then
        echo "Formatting ESP as FAT32..."
        mkfs.fat -F 32 -n EFI "$BOOT_PART"
    else
        echo "Formatting boot partition as ext4..."
        mkfs.ext4 -F -L boot "$BOOT_PART"
    fi
    
    # Show final partition details
    echo "Partitions created successfully:"
    echo "Boot: $BOOT_PART (type: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "ext4"))"
    echo "ZFS: $ZFS_PART (raw, wiped clean, ready for ZFS)"
    if [ "$REPLICATED_STORAGE_SIZE" != "0G" ]; then
        echo "Replicated storage: $REPLICATED_STORAGE_PART (raw, unformatted, wiped clean)"
    fi
    
    # Show final partition layout
    echo ""
    echo "Final partition layout:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,PARTLABEL "$INSTALL_DISK"
    
    # Additional verification with sgdisk
    echo ""
    echo "Partition table details:"
    sgdisk -p "$INSTALL_DISK"
    
    # Final sync to ensure all writes are complete
    sync
    echo "✓ Partitioning completed successfully"
}

# ---- ZFS Pool and Dataset Functions ----
function create_zfs_pool {
    echo "======= Creating ZFS pool =========="
    modprobe zfs
    
    zpool create -f -o ashift=12 \
    -o cachefile="none" \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O mountpoint=none \
    "$ZFS_POOL" "$ZFS_PART"

    zfs create -o mountpoint=none   "$ZFS_POOL/ROOT"
    zfs create -o mountpoint=legacy "$ZFS_POOL/ROOT/ubuntu"

    echo "======= Assigning $ZFS_POOL/ROOT/ubuntu dataset as bootable =========="
    zpool set bootfs="$ZFS_POOL/ROOT/ubuntu" "$ZFS_POOL"    
}

function create_additional_zfs_datasets {
    echo "======= Creating additional ZFS datasets with TEMPORARY mountpoints =========="
    
    # Ensure parent datasets are created first
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/ubuntu/var"
    
    # System datasets
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/tmp" "$ZFS_POOL/ROOT/ubuntu/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/ubuntu/tmp"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/tmp" "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/ubuntu/var/tmp"   
    
    # === SINGLE PARENT DATASET FOR ALL OPENEBS PVC ===
    # OpenEBS will create child datasets under this automatically
    zfs create -o mountpoint=none "$ZFS_POOL/openebs"
    zfs set compression=lz4 "$ZFS_POOL/openebs"
    zfs set atime=off "$ZFS_POOL/openebs"
    
    # Home dataset
    zfs create -o mountpoint="$TARGET/home" "$ZFS_POOL/home"
    
    # Mount all datasets
    zfs mount -a
    
    # Set permissions
    chmod 1777 "$TARGET/tmp"
    chmod 1777 "$TARGET/var/tmp"
    echo "✓ Kubernetes-optimized datasets created"
    echo "✓ Single parent dataset for OpenEBS ZFS Local PV: $ZFS_POOL/openebs"
}

function set_final_mountpoints {
    echo "======= Setting final mountpoints =========="
    
    # Leaf datasets - actual system mountpoints
    zfs set mountpoint=/tmp "$ZFS_POOL/ROOT/ubuntu/tmp"
    zfs set mountpoint=/var/tmp "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    
    # Home and databases datasets
    zfs set mountpoint=/home "$ZFS_POOL/home"    
    
    echo ""
    echo "Detailed dataset listing:"
    zfs list -o name,mountpoint -r "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_ubuntu_system {
    echo "======= Bootstrapping Ubuntu to temporary directory =========="
    TEMP_STAGE=$(mktemp -d)
    echo "Created temporary staging directory: $TEMP_STAGE"
    
    # Cleanup function for temp directory
    cleanup_temp_stage() {
        if [ -d "$TEMP_STAGE" ]; then
            echo "Cleaning up temporary staging directory..."
            rm -rf "$TEMP_STAGE"
        fi
    }
    
    # Add trap to ensure cleanup on script exit
    trap cleanup_temp_stage EXIT
    
    # Verify ubuntu-keyring is available (included in initramfs from Ubuntu build host)
    if [ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
        echo "ERROR: Ubuntu keyring not found at /usr/share/keyrings/ubuntu-archive-keyring.gpg"
        echo "This initramfs was built from a non-Ubuntu system. Please rebuild from Ubuntu."
        exit 1
    fi
    echo "✓ Ubuntu keyring found"
    
    # Install debootstrap if not already available
    if ! command -v debootstrap &>/dev/null; then
        echo "Installing debootstrap..."
        apt update
        apt install -y debootstrap
    fi

    # Use debootstrap to bootstrap Ubuntu (shell script, minimal dependencies)
    echo "Bootstrapping Ubuntu $UBUNTU_CODENAME with debootstrap..."
    debootstrap --arch=amd64 \
      --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
      --include=systemd-resolved,locales,debconf-i18n,apt-utils,keyboard-configuration,console-setup,kbd,initramfs-tools,zstd \
      "$UBUNTU_CODENAME" "$TEMP_STAGE" \
      "${MIRROR_SITE}/ubuntu/packages"

    echo "======= Copying staged system to ZFS datasets =========="
    # Mount root dataset for copying
    mkdir -p "$TARGET"
    mount -t zfs "$ZFS_POOL/ROOT/ubuntu" "$TARGET"

    create_additional_zfs_datasets

    # Use rsync to copy the entire system (this will populate all datasets)
    echo "Copying staged system to ZFS datasets..."
    rsync -aAX "$TEMP_STAGE/" "$TARGET/"

    echo "Staged system copied successfully"
    echo "Source size: $(du -sh "$TEMP_STAGE")"
    echo "Target size: $(du -sh "$TARGET")"

    # Clean up temp directory
    cleanup_temp_stage
    trap - EXIT
}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    mount -t tmpfs tmpfs "$TARGET/run"
    mount -t tmpfs tmpfs "$TARGET/tmp"
    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"

    configure_dns_resolution
}

function configure_dns_resolution {
    echo "======= Configuring DNS resolution =========="
    mkdir -p "$TARGET/run/systemd/resolve"
    
    # RAM OS doesn't run systemd, so resolvectl won't work
    # Copy DNS configuration from current /etc/resolv.conf instead
    if [ -f /etc/resolv.conf ] && grep -q 'nameserver' /etc/resolv.conf; then
        echo "Copying DNS configuration from /etc/resolv.conf..."
        # Extract nameserver lines
        grep '^nameserver' /etc/resolv.conf > "$TARGET/run/systemd/resolve/stub-resolv.conf"
        echo "DNS servers configured:"
        cat "$TARGET/run/systemd/resolve/stub-resolv.conf"
    else
        echo "No DNS configuration found in /etc/resolv.conf, using public DNS..."
        cat > "$TARGET/run/systemd/resolve/stub-resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF
        echo "Using public DNS servers: 8.8.8.8, 1.1.1.1, 8.8.4.4"
    fi
}

# ---- System Configuration Functions ----
function configure_basic_system {
    echo "======= Configuring basic system settings =========="
    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail

# Set hostname from variable
echo "$SYSTEM_HOSTNAME" > /etc/hostname

# Configure timezone (Vienna)
echo "Europe/Vienna" > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime

# Generate locales
cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
de_AT.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8  
ru_RU.UTF-8 UTF-8
LOCALES

locale-gen

# Set default locale
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Configure keyboard for German and US with Alt+Shift toggle
cat > /etc/default/keyboard <<'KEYBOARD'
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="de,ru"
XKBVARIANT=","
XKBOPTIONS="grp:ctrl_shift_toggle"

BACKSPACE="guess"
KEYBOARD

# Apply keyboard configuration to console
setupcon --force

# Update /etc/hosts with the hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $SYSTEM_HOSTNAME" >> /etc/hosts
echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1 ip6-allnodes" >> /etc/hosts
echo "ff02::2 ip6-allrouters" >> /etc/hosts

# Set proper permissions for ZFS datasets
chmod 1777 /tmp
chmod 1777 /var/tmp

# Set ZFS ARC size
echo options zfs zfs_arc_max=$((ZFS_ARC_SIZE * 1024 * 1024)) >> /etc/modprobe.d/zfs.conf
EOF

    echo "======= Configuration Summary ======="
    chroot "$TARGET" /bin/bash <<'EOF'
echo "Hostname: $(cat /etc/hostname)"
echo "Timezone: $(cat /etc/timezone)"
echo "Current time: $(date)"
echo "Default locale: $(grep LANG /etc/default/locale)"
echo "Available locales:"
locale -a | grep -E "(en_US|de_AT|fr_FR|ru_RU)"
echo "Keyboard layout: $(grep XKBLAYOUT /etc/default/keyboard)"
EOF
}

function install_system_packages {
    echo "======= Installing ZFS and essential packages in chroot =========="
    
    # Configure complete apt sources with all mirrors
    echo "Setting up apt sources..."
    cat > "$TARGET/etc/apt/sources.list" << SOURCES
# Ubuntu ${UBUNTU_CODENAME} - Main packages
${MIRROR_MAIN}

# Ubuntu ${UBUNTU_CODENAME} - Updates
${MIRROR_UPDATES}

# Ubuntu ${UBUNTU_CODENAME} - Backports
${MIRROR_BACKPORTS}

# Ubuntu ${UBUNTU_CODENAME} - Security updates
${MIRROR_SECURITY}
SOURCES
    echo "✓ Configured apt sources with Hetzner mirrors"
    
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
# Update package lists
apt update

# Install generic kernel (creates files in ZFS dataset /boot)
apt install -y --no-install-recommends linux-image-generic linux-headers-generic

# Install ZFS utilities and aux packages
# Note: In Ubuntu 24.04+, ZFS is integrated into linux-image-generic, no separate zfs-dkms needed

apt install -y zfsutils-linux zfs-initramfs software-properties-common bash curl nano htop net-tools ssh rsyslog

# Ensure ZFS module is included in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Generate initramfs with ZFS support
update-initramfs -u -k all

# Verify kernel installation
echo "Installed kernel packages:"
dpkg -l | grep linux-image
echo "Kernel version:"
ls /lib/modules/
echo "Kernel files in ZFS dataset:"
ls -la /boot/vmlinuz* /boot/initrd.img* 2>/dev/null || echo "No kernel files found"
EOF
}

function configure_ssh {
    echo "======= Setting up OpenSSH =========="
    mkdir -p "$TARGET/root/.ssh/"
    cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$TARGET/etc/ssh/sshd_config"
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$TARGET/etc/ssh/sshd_config"

    # Copy SSH host keys from RAM OS (inherits original server's keys for consistent fingerprint)
    echo "Copying SSH host keys from RAM OS..."
    
    # First remove any generated keys from the fresh install
    rm -f "$TARGET/etc/ssh/ssh_host_"* 2>/dev/null || true
    
    local keys_copied=0
    
    # Convert Dropbear keys back to OpenSSH format
    if [ -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        if dropbearconvert dropbear openssh /etc/dropbear/dropbear_ed25519_host_key "$TARGET/etc/ssh/ssh_host_ed25519_key" 2>/dev/null; then
            chmod 600 "$TARGET/etc/ssh/ssh_host_ed25519_key"
            echo "✓ Copied Ed25519 host key"
            keys_copied=$((keys_copied + 1))
        fi
    fi
    
    if [ -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
        if dropbearconvert dropbear openssh /etc/dropbear/dropbear_ecdsa_host_key "$TARGET/etc/ssh/ssh_host_ecdsa_key" 2>/dev/null; then
            chmod 600 "$TARGET/etc/ssh/ssh_host_ecdsa_key"
            echo "✓ Copied ECDSA host key"
            keys_copied=$((keys_copied + 1))
        fi
    fi
    
    if [ -f /etc/dropbear/dropbear_rsa_host_key ]; then
        if dropbearconvert dropbear openssh /etc/dropbear/dropbear_rsa_host_key "$TARGET/etc/ssh/ssh_host_rsa_key" 2>/dev/null; then
            chmod 600 "$TARGET/etc/ssh/ssh_host_rsa_key"
            echo "✓ Copied RSA host key"
            keys_copied=$((keys_copied + 1))
        fi
    fi
    
    # Generate public keys and fix up in chroot (where ssh-keygen is available)
    chroot "$TARGET" /bin/bash <<'EOF'
# Generate public keys from the copied private keys
for keyfile in /etc/ssh/ssh_host_*_key; do
    if [ -f "$keyfile" ] && [ ! -f "${keyfile}.pub" ]; then
        ssh-keygen -y -f "$keyfile" > "${keyfile}.pub" 2>/dev/null || true
        chmod 644 "${keyfile}.pub" 2>/dev/null || true
    fi
done
EOF
    
    # If no keys were copied, fall back to generating new ones
    if [ $keys_copied -eq 0 ]; then
        echo "[!] No host keys copied from RAM OS, generating new ones..."
        chroot "$TARGET" /bin/bash <<'EOF'
dpkg-reconfigure openssh-server -f noninteractive
EOF
    fi
}

function set_root_credentials {
    echo "======= Setting root password =========="
    chroot "$TARGET" /bin/bash -c "echo root:$(printf "%q" "$ROOT_PASSWORD") | chpasswd"

    echo "============ Setting up root prompt ============"
    cat > "$TARGET/root/.bashrc" <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF
}

# ---- Bootloader Functions ----
function setup_efi_boot {
    echo "======= Setting up EFI boot =========="
    
    # Mount EFI System Partition
    mkdir -p "$MAIN_BOOT"
    mount "$BOOT_PART" "$MAIN_BOOT"
    
    # Create EFI directory structure    
    mkdir -p "$MAIN_BOOT/EFI/Boot"
    
    # Download ZFSBootMenu EFI binary
    echo "Downloading ZFSBootMenu EFI binary from: $ZBM_EFI_URL"
    curl -L "$ZBM_EFI_URL" -o "$MAIN_BOOT/EFI/Boot/bootx64.efi"    
}

function setup_bios_boot {
    echo "======= Setting up BIOS boot =========="
    
    # Mount boot partition
    mkdir -p "$MAIN_BOOT"
    mount "$BOOT_PART" "$MAIN_BOOT"
    
    # Install extlinux in the target system (chroot)
    echo "Installing extlinux in target system..."
    chroot "$TARGET" apt update
    chroot "$TARGET" apt install -y extlinux syslinux-common
    
    # Bind-mount boot partition into chroot and run extlinux from there
    mkdir -p "$TARGET/boot/extlinux"
    mount --bind "$MAIN_BOOT" "$TARGET/boot/extlinux"
    chroot "$TARGET" extlinux --install /boot/extlinux
    umount "$TARGET/boot/extlinux"
    
    # Create extlinux configuration
    cat > "$MAIN_BOOT/extlinux.conf" << 'EOF'
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 0

LABEL zfsbootmenu
    LINUX /zfsbootmenu/vmlinuz-bootmenu
    INITRD /zfsbootmenu/initramfs-bootmenu.img
    APPEND ro quiet
EOF

    echo "Generated extlinux.conf:"
    cat "$MAIN_BOOT/extlinux.conf"
    
    # Download and install ZFSBootMenu for BIOS
    local TEMP_ZBM=$(mktemp -d)
    echo "Downloading ZFSBootMenu for BIOS from: $ZBM_BIOS_URL"
    curl -L "$ZBM_BIOS_URL" -o "$TEMP_ZBM/zbm.tar.gz"
    tar -xz -C "$TEMP_ZBM" -f "$TEMP_ZBM/zbm.tar.gz" --strip-components=1
    
    # Copy ZFSBootMenu to boot partition
    mkdir -p "$MAIN_BOOT/zfsbootmenu"
    cp "$TEMP_ZBM"/vmlinuz* "$MAIN_BOOT/zfsbootmenu/"
    cp "$TEMP_ZBM"/initramfs* "$MAIN_BOOT/zfsbootmenu/"
    
    # Clean up
    rm -rf "$TEMP_ZBM"
    
    echo "ZFSBootMenu files copied to boot partition:"
    ls -la "$MAIN_BOOT/zfsbootmenu/"
    
    # Install MBR from the target system and set boot flag
    # syslinux-common provides gptmbr.bin at /usr/lib/syslinux/mbr/
    local MBR_FILE=""
    if [ -f "$TARGET/usr/lib/syslinux/mbr/gptmbr.bin" ]; then
        MBR_FILE="$TARGET/usr/lib/syslinux/mbr/gptmbr.bin"
    elif [ -f "$TARGET/usr/lib/EXTLINUX/gptmbr.bin" ]; then
        MBR_FILE="$TARGET/usr/lib/EXTLINUX/gptmbr.bin"
    elif [ -f "$TARGET/usr/share/syslinux/gptmbr.bin" ]; then
        MBR_FILE="$TARGET/usr/share/syslinux/gptmbr.bin"
    fi
    
    if [ -n "$MBR_FILE" ]; then
        echo "Installing MBR from: $MBR_FILE"
        dd bs=440 conv=notrunc count=1 if="$MBR_FILE" of="$INSTALL_DISK"
    else
        echo "[!] Warning: gptmbr.bin not found, searching..."
        find "$TARGET/usr" -name "gptmbr.bin" 2>/dev/null
        echo "[!] MBR installation may have failed"
    fi
    
    parted "$INSTALL_DISK" set 1 boot on
    
    echo "BIOS boot setup complete"
}

function configure_bootloader {
    echo "======= Setting up boot based on firmware type =========="
    if [ "$EFI_MODE" = true ]; then
        setup_efi_boot
    else
        setup_bios_boot
    fi

    echo "======= Configuring ZFSBootMenu for auto-detection =========="
    zfs set org.zfsbootmenu:commandline="ro quiet" "$ZFS_POOL/ROOT/ubuntu"
    zfs set org.zfsbootmenu:active="on" "$ZFS_POOL/ROOT/ubuntu"

    echo "Boot configuration:"
    zfs get org.zfsbootmenu:commandline "$ZFS_POOL/ROOT/ubuntu"
}

# ---- System Services Functions ----
function configure_system_services {
    echo "======= Enabling essential system services =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail

systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

systemctl enable zfs-import-scan
systemctl disable zfs-import-cache

systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer

systemctl disable unattended-upgrades

echo "Enabled services:"
systemctl list-unit-files | grep enabled
EOF
}

function configure_networking {
    echo "======= Configuring Netplan for Hetzner Cloud =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
# Create Netplan configuration that matches all non-loopback interfaces
cat > /etc/netplan/01-hetzner.yaml <<'EOL'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-interfaces:
      match:
        name: "!lo"
      dhcp4: true
      dhcp6: true
      dhcp4-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      dhcp6-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      critical: true
EOL

# Set proper permissions - Netplan requires strict permissions (600)
chmod 600 /etc/netplan/01-hetzner.yaml
chown root:root /etc/netplan/01-hetzner.yaml

# Apply the Netplan configuration
netplan generate
echo "Netplan configuration created for all interfaces"
EOF
}

# ---- Cleanup and Finalization Functions ----
function unmount_all_datasets_and_partitions {
    echo "======= Unmounting all datasets =========="
    
    # First, unmount all auto-mounted ZFS datasets (tmp, var/tmp, var/log, etc.)
    echo "Unmounting auto-mounted ZFS datasets..."
    zfs umount -a 2>/dev/null || true
    
    # Manually unmount the root legacy dataset from $TARGET
    if mountpoint -q "$TARGET"; then
        echo "Unmounting root dataset from $TARGET"
        umount "$TARGET" 2>/dev/null || true
    fi
    
    # Manually unmount boot partition if mounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "Unmounting boot partition from $MAIN_BOOT"
        umount "$MAIN_BOOT" 2>/dev/null || true
    fi
    
    # Wait for unmounts to complete
    sleep 1
    
    # Force unmount any stubborn datasets
    if zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -q "yes"; then
        echo "Forcing unmount of remaining ZFS datasets..."
        zfs umount -a -f 2>/dev/null || true
    fi
    
    # Final verification
    local mounted_count=0
    mounted_count=$(zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -c "yes" || true)
    
    if [ "$mounted_count" -gt 0 ]; then
        echo "WARNING: $mounted_count dataset(s) still mounted after unmount attempt:"
        zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep "yes" || true
    else
        echo "✓ All ZFS datasets successfully unmounted"
    fi
    
    # Verify $TARGET is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted!"
        mount | grep "$TARGET" || true
    else
        echo "✓ $TARGET successfully unmounted"
    fi
    
    # Verify $MAIN_BOOT is unmounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "WARNING: $MAIN_BOOT is still mounted!"
        mount | grep "$MAIN_BOOT" || true
    else
        echo "✓ $MAIN_BOOT successfully unmounted"
    fi
}

function unmount_chroot_environment {
    echo "======= Unmounting virtual filesystems =========="
    # Unmount virtual filesystems first
    for dir in dev/pts dev tmp run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
}

function finalize_system_resolved {
    echo "======= Setting systemd-resolved configuration for final boot =========="
    # This must be done while $TARGET is still mounted
    mkdir -p "$TARGET/run/systemd/resolve"
    cat > "$TARGET/run/systemd/resolve/stub-resolv.conf" << 'EOF'
nameserver 127.0.0.53
options edns0 trust-ad
search .
EOF
    echo "✓ systemd-resolved configuration set"
}

function export_zfs_pool {
    echo "======= Exporting ZFS pool =========="
    zpool export "$ZFS_POOL" 2>/dev/null || true

    # Verify everything is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted!"
        mount | grep "$TARGET"
    else
        echo "✓ All filesystems successfully unmounted"
    fi
}

function show_final_instructions {
    echo ""
    echo "=========================================="
    echo "  INSTALLATION COMPLETE! "
    echo "=========================================="
    echo ""
    echo "System Information:"
    echo "  Hostname: $SYSTEM_HOSTNAME"
    echo "  ZFS Pool: $ZFS_POOL"
    echo "  Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")"
    echo "  Ubuntu Version: $UBUNTU_CODENAME"
    echo "  Networking: systemd-networkd + systemd-resolved"
    echo ""
    echo "Partition Layout:"
    echo "  Boot: 128MB ($BOOT_PART)"
    echo "  ZFS: $(lsblk -n -o SIZE "$ZFS_PART") ($ZFS_PART)"
    echo "  Replicated storage: $REPLICATED_STORAGE_SIZE ($REPLICATED_STORAGE_PART - raw)"
    echo ""
    echo "ZFS Datasets Created:"
    echo "  $ZFS_POOL/ROOT/ubuntu - Root system"
    echo "  $ZFS_POOL/databases - Parent for databases"
    echo "  $ZFS_POOL/home - User home directories"
    echo "  Various system datasets (tmp, log, containers)"
    echo ""
    echo "=========================================="
    echo ""
    echo "⚠️  System will now reboot into the new installation."
    echo ""
    echo "Your SSH connection will be disconnected."
    echo "Wait 30-60 seconds, then reconnect with:"
    echo "  ssh root@<server-ip>"
    echo ""
    echo "Rebooting in 5 seconds..."
    sleep 5
}

# ---- Main Execution Function ----
function main {
    echo "Starting ZFS Ubuntu installation on Hetzner Cloud..."
    
    # Phase 0: User input
    get_user_input
    
    # Phase 1: System detection and preparation
    detect_efi
    find_install_disk
    
    # Show summary and get final confirmation
    show_summary_and_confirm
    
    remove_unused_kernels
    
    # Phase 2: Disk partitioning and ZFS setup
    partition_disk
    create_zfs_pool
    
    # Phase 3: System bootstrap
    bootstrap_ubuntu_system
    setup_chroot_environment
    
    # Phase 4: System configuration
    configure_basic_system
    install_system_packages
    configure_ssh
    set_root_credentials
    configure_system_services
    configure_networking
    
    # Phase 5: Bootloader setup
    configure_bootloader
    
    # Phase 6: Cleanup and finalization
    unmount_chroot_environment
    finalize_system_resolved    
    unmount_all_datasets_and_partitions
    
    # Phase 7: Final mountpoints and export    
    set_final_mountpoints
    
    export_zfs_pool
    
    show_final_instructions
    
    reboot
}

# Execute main function
main "$@"

