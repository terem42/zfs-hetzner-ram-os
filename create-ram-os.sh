#!/bin/bash
set -e

echo "=== Creating Minimal RAM System with BusyBox and Dropbear ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root"
    echo "Please run with: sudo $0"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
KERNEL_VERSION=$(uname -r)
KERNEL_IMAGE="/boot/vmlinuz-$KERNEL_VERSION"
CUSTOM_INITRAMFS="/tmp/minimal-ram-system.img"
BUNDLE_OUTPUT="/tmp/zfs-ram-system.tar.gz"
SSH_PORT="22"

# SSH public key injection moved to deployment time
# No SSH keys are hardcoded into the initramfs during build

# Function definitions - must be defined before use
# Colors for terminal output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[!]${NC} $1"; }

print_status "Using SSH key: $SSH_KEY_FILE"


# Locate SSH host keys
DROPBEAR_KEY_DIR="/etc/dropbear"
OPENSSH_KEY_DIR="/etc/ssh"

# Find binary using whereis
find_binary() {
    local bin_name=$1
    local result=$(whereis -b "$bin_name" 2>/dev/null | awk '{print $2}')
    if [ -n "$result" ] && [ -f "$result" ]; then
        echo "$result"
        return 0
    fi
    return 1
}

# Check dependencies
check_dependencies() {
    print_status "Checking dependencies..."
    
    local deps=("kexec-tools" "busybox-static" "dropbear-initramfs" "zfsutils-linux" \
                "parted" "util-linux" \
                "dosfstools" "e2fsprogs" \
                "apt" "dpkg" "debootstrap" "debconf" \
                "curl" "wget" "rsync" "zstd" \
                "systemd" "udev" "bc" "whiptail" \
                "gcc" "libc6-dev")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$dep" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_status "Installing missing dependencies: ${missing[*]}"
        apt update
        apt install -y "${missing[@]}"
    fi
}

# Get library dependencies for a binary
get_binary_libs() {
    local binary=$1
    ldd "$binary" 2>/dev/null | awk '
        /=>/ {print $3}
        /\// && !/=>/ {print $1}
    ' | grep -v "^(" | sort -u
}

# Create minimal initramfs
create_minimal_initramfs() {
    print_status "Creating minimal initramfs..."
    
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Create essential directory structure
    mkdir -p {bin,dev,etc,lib,lib64,proc,root,sbin,sys,tmp,usr/bin,usr/sbin,var/run,run,mnt,etc/dropbear,root/.ssh}
    chmod 1777 tmp
    
    # Create essential device nodes
    print_status "Creating device nodes..."
    mknod dev/console c 5 1 2>/dev/null || true
    mknod dev/null c 1 3 2>/dev/null || true
    mknod dev/zero c 1 5 2>/dev/null || true
    mkdir -p dev/pts
    ln -s /proc/self/fd dev/fd 2>/dev/null || true
    
    # Find and copy BusyBox
    print_status "Setting up BusyBox..."
    local busybox_path=$(find_binary "busybox")
    if [ -z "$busybox_path" ]; then
        print_error "BusyBox not found!"
        return 1
    fi
    
    print_status "Found BusyBox at: $busybox_path"
    cp "$busybox_path" bin/
    chmod +x bin/busybox
    
    # Create symlinks for all BusyBox applets (skip existing and skip commands where we have better alternatives)
    print_status "Creating BusyBox symlinks..."
    cd bin
    # Skip wget and curl - we have GNU versions with proper TLS/SSL support
    # Skip sh - BusyBox ash has internal applets that override executables (breaks debootstrap)
    # Skip reboot/poweroff/halt - we have safe wrapper scripts in /sbin
    local skip_applets="wget curl sh reboot poweroff halt"
    for applet in $(./busybox --list); do
        if [ ! -e "$applet" ] && ! echo "$skip_applets" | grep -Fqw "$applet"; then
            ln -s busybox "$applet" 2>/dev/null || true
        fi
    done
    # Link /bin/sh to bash (not busybox) - BusyBox ash has internal wget that breaks TLS
    ln -sf /sbin/bash sh
    cd ..
    
    # Create /usr/bin symlinks for tools that debootstrap expects there
    mkdir -p usr/bin
    ln -sf /sbin/dpkg usr/bin/dpkg
    
    # Find and copy Dropbear
    print_status "Setting up Dropbear..."
    local dropbear_path=$(find_binary "dropbear")
    local dropbearkey_path=$(find_binary "dropbearkey")
    local dropbearconvert_path=$(find_binary "dropbearconvert")
    
    if [ -z "$dropbear_path" ] || [ -z "$dropbearkey_path" ] || [ -z "$dropbearconvert_path" ]; then
        print_error "Dropbear tools not found! Need: dropbear, dropbearkey, dropbearconvert"
        print_error "Install with: apt install dropbear-bin"
        return 1
    fi
    
    print_status "Found dropbear at: $dropbear_path"
    print_status "Found dropbearkey at: $dropbearkey_path"
    
    cp "$dropbear_path" usr/bin/
    cp "$dropbearkey_path" usr/bin/
    chmod +x usr/bin/dropbear
    chmod +x usr/bin/dropbearkey
    
    # Copy dropbearconvert (required for SSH key conversion)
    print_status "Found dropbearconvert at: $dropbearconvert_path"
    cp "$dropbearconvert_path" usr/bin/
    chmod +x usr/bin/dropbearconvert
    
    # Copy dbclient (Dropbear's SSH client)
    local dbclient_path=$(find_binary "dbclient")
    if [ -n "$dbclient_path" ]; then
        print_status "Found dbclient at: $dbclient_path"
        cp "$dbclient_path" usr/bin/
        chmod +x usr/bin/dbclient
        # Create ssh symlink for convenience
        ln -sf dbclient usr/bin/ssh
    else
        print_warning "dbclient not found, SSH client will not be available"
    fi
    
    # Copy ssh-keygen for key management in rescue scenarios
    local sshkeygen_path=$(find_binary "ssh-keygen")
    if [ -n "$sshkeygen_path" ]; then
        print_status "Found ssh-keygen at: $sshkeygen_path"
        cp "$sshkeygen_path" usr/bin/
        chmod +x usr/bin/ssh-keygen
    else
        print_warning "ssh-keygen not found"
    fi
    
    # Copy sftp-server for scp/sftp file transfer support
    local sftp_server_path="/usr/lib/openssh/sftp-server"
    if [ -f "$sftp_server_path" ]; then
        print_status "Found sftp-server at: $sftp_server_path"
        mkdir -p usr/lib
        cp "$sftp_server_path" usr/lib/sftp-server
        chmod +x usr/lib/sftp-server
        # Also copy libraries needed by sftp-server
        for lib in $(get_binary_libs "$sftp_server_path"); do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp "$lib" "./$lib" 2>/dev/null || true
            fi
        done
    else
        print_warning "sftp-server not found, scp transfers may not work"
    fi
    
    # Copy essential libraries
    print_status "Copying essential libraries..."
    
    # Get libraries for BusyBox
    for lib in $(get_binary_libs "$busybox_path"); do
        if [ -f "$lib" ]; then
            mkdir -p "./$(dirname "$lib")"
            cp "$lib" "./$lib" 2>/dev/null || print_warning "Failed to copy library: $lib"
        fi
    done
    
    # Get libraries for Dropbear
    for lib in $(get_binary_libs "$dropbear_path"); do
        if [ -f "$lib" ]; then
            mkdir -p "./$(dirname "$lib")"
            cp "$lib" "./$lib" 2>/dev/null || print_warning "Failed to copy library: $lib"
        fi
    done
    
    # Get libraries for dropbearkey
    for lib in $(get_binary_libs "$dropbearkey_path"); do
        if [ -f "$lib" ]; then
            mkdir -p "./$(dirname "$lib")"
            cp "$lib" "./$lib" 2>/dev/null || print_warning "Failed to copy library: $lib"
        fi
    done
    
    # Get libraries for dropbearconvert
    for lib in $(get_binary_libs "$dropbearconvert_path"); do
        if [ -f "$lib" ]; then
            mkdir -p "./$(dirname "$lib")"
            cp "$lib" "./$lib" 2>/dev/null || print_warning "Failed to copy library: $lib"
        fi
    done
    
    # Copy essential system binaries
    print_status "Copying essential system binaries..."
    
    # Critical binaries that MUST be present for the installation to work
    local critical_binaries=(
        "zpool" "zfs" "sgdisk" "debootstrap" "chroot"
    )
    
    # Complete list of binaries for ZFS installation
    local all_binaries=(
        # Kernel module utilities
        "modprobe" "insmod" "lsmod" "depmod"
        
        # ZFS tools (essential only, no testing tools)
        "zpool" "zfs" "zdb" "zgenhostid" "mount.zfs" "fsck.zfs"
        "zstreamdump"
        "arc_summary" "arcstat" "dbufstat" "zilstat"
        
        # Disk partitioning
        "sgdisk" "parted" "partprobe"
        "blkid" "lsblk" "findmnt"
        
        # Filesystem creation
        "mkfs.fat" "mkfs.vfat" "mkfs.ext4" "mkfs.ext3"
        
        # Package management (for debootstrap)
        "apt" "apt-get" "apt-cache" "dpkg" "dpkg-deb"
        "debootstrap"
        
        # GPG for package signature verification
        "gpg" "gpgv"
        
        # Download and transfer
        "curl" "wget" "rsync"
        
        # Archive tools
        "tar" "gzip" "gunzip" "bzip2" "bunzip2" "xz" "unxz" "zstd" "zstdcat"
        
        # System utilities
        "udevadm" "systemctl" "resolvectl" "chroot"
        "mount" "umount" "mountpoint" "swapon" "swapoff"
        
        # Text processing (not in BusyBox or needed explicitly)
        "bc"
        
        # User interface
        "whiptail"
        
        # Keyboard support
        "loadkeys"
        
        # System monitoring and editors
        "htop" "nano"
        
        # Shell
        "bash"
    )
    
    local missing_critical=()
    
    for bin in "${all_binaries[@]}"; do
        local bin_path=$(find_binary "$bin")
        if [ -n "$bin_path" ]; then
            print_status "Found $bin at: $bin_path"
            cp "$bin_path" sbin/ 2>/dev/null || cp "$bin_path" bin/ 2>/dev/null || true
            
            # Copy libraries for this binary too
            for lib in $(get_binary_libs "$bin_path"); do
                if [ -f "$lib" ]; then
                    mkdir -p "./$(dirname "$lib")"
                    cp "$lib" "./$lib" 2>/dev/null || true
                fi
            done
        else
            # Check if this is a critical binary
            if [[ " ${critical_binaries[*]} " =~ " $bin " ]]; then
                print_error "CRITICAL: $bin not found!"
                missing_critical+=("$bin")
            else
                print_warning "$bin not found (optional)"
            fi
        fi
    done
    
    # If critical binaries are missing, prompt user to install
    if [ ${#missing_critical[@]} -gt 0 ]; then
        echo ""
        print_error "The following critical binaries are missing:"
        for bin in "${missing_critical[@]}"; do
            echo "  - $bin"
        done
        echo ""
        echo "Suggested packages to install:"
        echo "  apt install zfsutils-linux debootstrap gdisk"
        echo ""
        read -p "Would you like to install missing packages now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Installing suggested packages..."
            apt update
            apt install -y zfsutils-linux debootstrap gdisk
            print_status "Packages installed. Please re-run this script."
            exit 0
        else
            print_error "Cannot continue without critical binaries."
            exit 1
        fi
    fi
    
    # Create SSH directory structure (keys will be injected at runtime by installer)
    print_status "Creating SSH directory structure (keys injected at runtime)..."
    mkdir -p etc/dropbear
    
    # Copy kexec for embedded fallback (in case target system lacks kexec-tools)
    print_status "Copying kexec for embedded fallback..."
    local kexec_path=$(find_binary "kexec")
    if [ -n "$kexec_path" ]; then
        cp "$kexec_path" sbin/kexec
        chmod +x sbin/kexec
        print_status "kexec embedded at /sbin/kexec"
    else
        print_warning "kexec not found - embedded fallback will not be available"
    fi
    
    # Copy APT configuration for package management
    print_status "Copying APT configuration..."
    mkdir -p etc/apt etc/apt/sources.list.d etc/apt/trusted.gpg.d
    cp -r /etc/apt/sources.list* etc/apt/ 2>/dev/null || true
    cp -r /etc/apt/trusted.gpg* etc/apt/ 2>/dev/null || true
    
    # Copy keyrings for package verification
    mkdir -p usr/share/keyrings
    cp /usr/share/keyrings/*.gpg usr/share/keyrings/ 2>/dev/null || true
    
    # Create dpkg database structure
    mkdir -p var/lib/dpkg/{info,updates,triggers}
    mkdir -p var/lib/apt/lists
    mkdir -p var/cache/apt/archives
    touch var/lib/dpkg/status
    touch var/lib/dpkg/available
    
    print_status "APT configuration copied"
    
    # Copy debootstrap scripts and functions
    print_status "Copying debootstrap support files..."
    if [ -d /usr/share/debootstrap ]; then
        mkdir -p usr/share/debootstrap
        cp -r /usr/share/debootstrap/* usr/share/debootstrap/ 2>/dev/null || true
        print_status "Debootstrap scripts copied"
    else
        print_warning "Debootstrap support files not found, will be downloaded at runtime"
    fi
    
    # Build and install pkgdetails for debootstrap (replaces Perl dependency)
    # debootstrap needs either Perl or pkgdetails to parse package metadata
    print_status "Building pkgdetails for debootstrap (avoids Perl dependency)..."
    local pkgdetails_dir=$(mktemp -d)
    local base_installer_url="https://salsa.debian.org/installer-team/base-installer/-/raw/master/pkgdetails.c"
    
    # Download pkgdetails.c from Ubuntu base-installer source
    if ! curl -sL "$base_installer_url" -o "$pkgdetails_dir/pkgdetails.c"; then
        print_error "Failed to download pkgdetails.c"
        rm -rf "$pkgdetails_dir"
        exit 1
    fi
    
    # Compile pkgdetails - try static first, fall back to dynamic
    if gcc -static -o "$pkgdetails_dir/pkgdetails" "$pkgdetails_dir/pkgdetails.c" 2>/dev/null; then
        print_status "pkgdetails compiled successfully (static)"
    elif gcc -o "$pkgdetails_dir/pkgdetails" "$pkgdetails_dir/pkgdetails.c" 2>/dev/null; then
        print_status "pkgdetails compiled successfully (dynamic)"
        # Copy required libraries for dynamic binary
        for lib in $(get_binary_libs "$pkgdetails_dir/pkgdetails"); do
            if [ -f "$lib" ]; then
                mkdir -p "./$(dirname "$lib")"
                cp "$lib" "./$lib" 2>/dev/null || true
            fi
        done
    else
        print_error "Failed to compile pkgdetails - is gcc installed?"
        rm -rf "$pkgdetails_dir"
        exit 1
    fi
    
    # Install pkgdetails to the debootstrap lib directory
    mkdir -p usr/lib/debootstrap
    cp "$pkgdetails_dir/pkgdetails" usr/lib/debootstrap/
    chmod +x usr/lib/debootstrap/pkgdetails
    rm -rf "$pkgdetails_dir"
    print_status "pkgdetails installed to /usr/lib/debootstrap/"
    
    # Copy CA certificates for HTTPS support
    print_status "Copying CA certificates..."
    mkdir -p etc/ssl/certs usr/share/ca-certificates
    if [ -d /etc/ssl/certs ]; then
        cp -r /etc/ssl/certs/* etc/ssl/certs/ 2>/dev/null || true
    fi
    if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        cp /etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ 2>/dev/null || true
    fi
    if [ -d /usr/share/ca-certificates ]; then
        cp -r /usr/share/ca-certificates/* usr/share/ca-certificates/ 2>/dev/null || true
    fi
    print_status "CA certificates copied"
    
    # Create wgetrc to configure CA certificate path (wget needs this explicitly)
    echo "ca-certificate = /etc/ssl/certs/ca-certificates.crt" > etc/wgetrc
    print_status "wget configured with CA certificates"
    
    # Copy terminfo for terminal-based programs (htop, nano, etc.)
    print_status "Copying terminfo database..."
    if [ -d /usr/share/terminfo ]; then
        mkdir -p usr/share/terminfo
        # Copy essential terminal types
        for term_type in x/xterm x/xterm-256color l/linux v/vt100 v/vt220 s/screen; do
            term_dir=$(dirname "$term_type")
            mkdir -p "usr/share/terminfo/$term_dir"
            cp "/usr/share/terminfo/$term_type" "usr/share/terminfo/$term_type" 2>/dev/null || true
        done
        print_status "Terminfo database copied"
    fi
    
    # Copy minimal locale data for UTF-8 support
    print_status "Copying locale data..."
    mkdir -p usr/lib/locale
    if [ -d /usr/lib/locale/C.utf8 ]; then
        cp -r /usr/lib/locale/C.utf8 usr/lib/locale/
        print_status "C.utf8 locale copied"
    elif [ -d /usr/lib/locale/C.UTF-8 ]; then
        cp -r /usr/lib/locale/C.UTF-8 usr/lib/locale/
        print_status "C.UTF-8 locale copied"
    else
        print_warning "No C.utf8/C.UTF-8 locale found on host"
    fi
    
    # Copy keyboard/console setup files for German keyboard support
    print_status "Copying keyboard configuration..."
    if [ -d /etc/console-setup ]; then
        mkdir -p etc/console-setup
        cp /etc/console-setup/*.kmap.gz etc/console-setup/ 2>/dev/null || true
        cp /etc/console-setup/cached_setup_keyboard.sh etc/console-setup/ 2>/dev/null || true
        print_status "Console setup files copied"
    fi
    if [ -d /usr/share/console-setup ]; then
        mkdir -p usr/share/console-setup
        cp -r /usr/share/console-setup/* usr/share/console-setup/ 2>/dev/null || true
    fi
    
    # Embed installation script
    print_status "Embedding installation script..."
    local script_path="$SCRIPT_DIR/install_os.sh"
    if [ -f "$script_path" ]; then
        cp "$script_path" root/
        chmod +x root/install_os.sh
        print_status "Installation script embedded at /root/install_os.sh"
    else
        print_warning "Installation script not found at $script_path"
    fi
    
    # Copy kernel modules (minimal set)
    print_status "Copying kernel modules..."
    local modules_dir="./lib/modules/$KERNEL_VERSION"
    mkdir -p "$modules_dir"
    
    # First, find and copy ZFS modules from anywhere in the kernel modules tree
    print_status "Searching for ZFS modules..."
    local zfs_module_count=0
    
    # Find all ZFS-related modules (zfs, spl, zavl, etc.)
    while IFS= read -r -d '' module_file; do
        local rel_path="${module_file#/lib/modules/$KERNEL_VERSION/}"
        local dest_dir="$modules_dir/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp "$module_file" "$dest_dir/" 2>/dev/null && zfs_module_count=$((zfs_module_count + 1))
    done < <(find "/lib/modules/$KERNEL_VERSION" -type f \( -name "zfs.ko*" -o -name "spl.ko*" -o -name "zavl.ko*" -o -name "zcommon.ko*" -o -name "zlua.ko*" -o -name "znvpair.ko*" -o -name "zunicode.ko*" -o -name "zzstd.ko*" -o -name "icp.ko*" -o -name "fat.ko*" -o -name "vfat.ko*" -o -name "nls_*.ko*" \) -print0 2>/dev/null)
    
    if [ $zfs_module_count -gt 0 ]; then
        print_status "Found and copied $zfs_module_count ZFS module(s)"
    else
        print_warning "No ZFS modules found in /lib/modules/$KERNEL_VERSION"
        print_warning "Checking if ZFS is installed..."
        if command -v zpool &>/dev/null; then
            modinfo zfs 2>/dev/null | head -5 || true
        fi
    fi
    
    # Copy other essential modules from known paths
    local essential_modules=(
        "kernel/drivers/block"
        "kernel/drivers/nvme"
        "kernel/drivers/scsi"
    )
    
    local module_count=$zfs_module_count
    for module_path in "${essential_modules[@]}"; do
        local src_dir="/lib/modules/$KERNEL_VERSION/$module_path"
        if [ -d "$src_dir" ]; then
            mkdir -p "$modules_dir/$module_path"
            # Copy all .ko and .ko.* files recursively (includes compressed modules)
            local copied=$(find "$src_dir" -type f \( -name "*.ko" -o -name "*.ko.*" \) -exec cp {} "$modules_dir/$module_path/" 2>/dev/null \; -print | wc -l)
            if [ $copied -gt 0 ]; then
                print_status "Copied $copied module(s) from $module_path"
                module_count=$((module_count + copied))
            fi
        fi
    done
    
    print_status "Total kernel modules copied: $module_count"
    
    # Decompress modules to ensure compatibility with BusyBox modprobe
    print_status "Ensuring modules are decompressed..."
    find "$modules_dir" -type f -name "*.ko.zst" -exec zstd -d --rm -q {} + 2>/dev/null || true
    find "$modules_dir" -type f -name "*.ko.gz" -exec gzip -d {} + 2>/dev/null || true
    find "$modules_dir" -type f -name "*.ko.xz" -exec xz -d {} + 2>/dev/null || true
    
    # Verify ZFS modules are present
    local zfs_modules_found=$(find "$modules_dir" \( -name "zfs.ko*" -o -name "spl.ko*" \) 2>/dev/null | wc -l)
    if [ $zfs_modules_found -gt 0 ]; then
        print_status "ZFS modules verified: $zfs_modules_found core module(s) found"
    else
        print_error "CRITICAL: No ZFS modules found! ZFS will not work."
        print_error "Please ensure ZFS is properly installed: apt install zfsutils-linux"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Generate modules.dep if depmod is available
    if [ -x sbin/depmod ] || [ -x bin/depmod ]; then
        print_status "Generating module dependencies..."
        depmod -b "." "$KERNEL_VERSION" 2>/dev/null || true
    fi
    
    # Create init script with DHCP/dynamic networking
    print_status "Creating init script..."
    
    cat > init << EOF
#!/bin/busybox sh

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Setup tmpfs with size limits for RAM disk areas
mount -t tmpfs -o size=1G tmpfs /tmp
mount -t tmpfs -o size=64M tmpfs /run
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Additional tmpfs mounts for package management
mkdir -p /var/tmp /var/cache/apt/archives
mount -t tmpfs -o size=128M tmpfs /var/tmp
mount -t tmpfs -o size=512M tmpfs /var/cache/apt

# Set up environment
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export LD_LIBRARY_PATH=/lib:/usr/lib:/lib64:/usr/lib64

# SSL certificate paths for wget/curl (BusyBox wget needs these explicitly)
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs

# Set locale environment (C.utf8 is always available if copied)
export LANG=C.utf8
export LC_ALL=C.utf8

# Set terminal type for curses-based programs (htop, nano, whiptail, etc.)
# Use xterm-256color instead of linux for better UTF-8 line drawing
export TERM=xterm-256color

# Fix ncurses/whiptail line drawing in console (use UTF-8 box drawing instead of ACS)
export NCURSES_NO_UTF8_ACS=1

# Configure keyboard layout (German default)
setup_keyboard() {
    echo "Configuring keyboard layout..."
    
    # Load keyboard map if loadkeys is available
    if command -v loadkeys >/dev/null 2>&1; then
        # Try to load the cached keymap from console-setup (Ubuntu/Debian style)
        if [ -f /etc/console-setup/cached_UTF-8_del.kmap.gz ]; then
            zcat /etc/console-setup/cached_UTF-8_del.kmap.gz | loadkeys - 2>/dev/null && \
                echo "Loaded keyboard layout from console-setup" || \
                echo "Failed to load cached keymap"
        # Fallback to traditional German keymap
        elif loadkeys de-latin1 2>/dev/null; then
            echo "Loaded German keyboard layout"
        else
            echo "German keymap not available, using default"
        fi
    else
        echo "loadkeys not available, keyboard will use default layout"
    fi
    
    # Create keyboard switching aliases
    echo "Creating keyboard layout shortcuts..."
    cat >> /root/.profile << 'KBDEOF'
# Keyboard layout switching aliases
# NOTE: These are only needed for physical console or KVM access.
#       SSH sessions use your local machine's keyboard layout automatically.
alias kbd-de='loadkeys de-latin1 2>/dev/null && echo "Switched to German keyboard"'
alias kbd-fr='loadkeys fr-latin1 2>/dev/null && echo "Switched to French keyboard"'
alias kbd-ru='loadkeys ru 2>/dev/null && echo "Switched to Russian keyboard"'
alias kbd-us='loadkeys us 2>/dev/null && echo "Switched to US keyboard"'

# Source .bashrc for login shells
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
KBDEOF
}

setup_keyboard

echo "=== Minimal RAM System ==="
echo "Kernel: \$(uname -r)"
busybox | head -1

# Load essential modules
load_modules() {
    echo "Loading kernel modules..."
    modprobe zfs 2>/dev/null && echo "Loaded ZFS" || echo "ZFS module not available"
    
    # Load block device modules
    modprobe nvme 2>/dev/null
    modprobe scsi_mod 2>/dev/null
    modprobe sd_mod 2>/dev/null
    modprobe virtio_blk 2>/dev/null
    
    # Load network modules
    modprobe virtio_net 2>/dev/null
    modprobe e1000 2>/dev/null
    modprobe e1000e 2>/dev/null
    modprobe igb 2>/dev/null
    modprobe ixgbe 2>/dev/null
    modprobe r8169 2>/dev/null
    modprobe tg3 2>/dev/null
}

# Parse kernel command line for IP parameters (ip=<client-ip>::<gateway>:<netmask>:<hostname>:<device>:off)
parse_cmdline_ip() {
    local cmdline="\$(cat /proc/cmdline)"
    
    # Look for ip= parameter in kernel cmdline
    for param in \$cmdline; do
        case "\$param" in
            ip=*)
                echo "\${param#ip=}"
                return 0
                ;;
        esac
    done
    return 1
}

# Parse kernel command line for network MAC (netmac=<mac>)
parse_cmdline_mac() {
    local cmdline="\$(cat /proc/cmdline)"
    
    for param in \$cmdline; do
        case "\$param" in
            netmac=*)
                echo "\${param#netmac=}"
                return 0
                ;;
        esac
    done
    return 1
}

# Find interface by MAC address (handles name differences between systemd/legacy)
find_iface_by_mac() {
    local target_mac="\$1"
    [ -z "\$target_mac" ] && return 1
    
    for iface_path in /sys/class/net/*; do
        [ -d "\$iface_path" ] || continue
        local iface=\$(basename "\$iface_path")
        [ "\$iface" = "lo" ] && continue
        
        local mac=\$(cat "\$iface_path/address" 2>/dev/null)
        if [ "\$mac" = "\$target_mac" ]; then
            echo "\$iface"
            return 0
        fi
    done
    return 1
}

# Convert CIDR to netmask
cidr_to_netmask() {
    local cidr=\$1
    case "\$cidr" in
        32) echo "255.255.255.255" ;;
        31) echo "255.255.255.254" ;;
        30) echo "255.255.255.252" ;;
        29) echo "255.255.255.248" ;;
        28) echo "255.255.255.240" ;;
        27) echo "255.255.255.224" ;;
        26) echo "255.255.255.192" ;;
        25) echo "255.255.255.128" ;;
        24) echo "255.255.255.0" ;;
        23) echo "255.255.254.0" ;;
        22) echo "255.255.252.0" ;;
        21) echo "255.255.248.0" ;;
        20) echo "255.255.240.0" ;;
        16) echo "255.255.0.0" ;;
        8) echo "255.0.0.0" ;;
        *) echo "255.255.255.0" ;;
    esac
}

# Network setup using DHCP or inherited IP from kernel cmdline
setup_network() {
    echo "Setting up network..."
    
    # Coldplug: trigger device discovery for all devices (needed without udev)
    # This ensures network interfaces appear even with builtin drivers
    echo "Triggering device discovery..."
    for uevent in /sys/class/net/*/uevent /sys/bus/*/devices/*/uevent; do
        [ -f "\$uevent" ] && echo add > "\$uevent" 2>/dev/null || true
    done
    # Small delay for devices to settle
    sleep 1
    
    # Bring up loopback
    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
    
    # Use network config file if available (multi-interface support)
    if [ -x /etc/network_config.sh ]; then
        echo "Configuring network from captured config..."
        . /etc/network_config.sh
        
        # Configure DNS
        echo "Configuring DNS servers..."
        # Use DNS from initramfs if available, else use public resolvers
        if [ -f /etc/resolv.conf ] && grep -q nameserver /etc/resolv.conf; then
            echo "Using injected DNS configuration"
        else
            cat > /etc/resolv.conf << 'DNS_CONF'
# DNS configuration for RAM OS
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
DNS_CONF
            echo "DNS configured with public resolvers"
        fi
    else
        # Fallback: DHCP on first interface
        echo "No network config found, falling back to DHCP..."
        
        local iface=""
        for potential_iface in /sys/class/net/eth* /sys/class/net/en*; do
            if [ -d "\$potential_iface" ]; then
                iface=\$(basename "\$potential_iface")
                echo "Found interface: \$iface"
                break
            fi
        done
        
        if [ -z "\$iface" ]; then
            echo "No Ethernet interface found"
            return 1
        fi
        
        ifconfig "\$iface" up
        
        # Create simple udhcpc script for BusyBox
        mkdir -p /usr/share/udhcpc
        cat > /usr/share/udhcpc/default.script << 'DHCP_SCRIPT'
#!/bin/sh
case "\$1" in
    deconfig)
        ifconfig "\$interface" 0.0.0.0
        ;;
    bound|renew)
        ifconfig "\$interface" "\$ip" netmask "\${subnet:-255.255.255.0}" up
        if [ -n "\$router" ]; then
            while route del default gw 0.0.0.0 dev "\$interface" 2>/dev/null; do :; done
            for gw in \$router; do
                route add default gw "\$gw" dev "\$interface"
            done
        fi
        if [ -n "\$dns" ]; then
            echo -n > /etc/resolv.conf
            for ns in \$dns; do
                echo "nameserver \$ns" >> /etc/resolv.conf
            done
        fi
        ;;
esac
DHCP_SCRIPT
        chmod +x /usr/share/udhcpc/default.script
        
        if udhcpc -i "\$iface" -t 10 -T 3 -n -q -s /usr/share/udhcpc/default.script; then
            echo "DHCP successful"
        else
            echo "DHCP failed, no IP configured"
            return 1
        fi
    fi
    
    # Show configuration summary
    echo ""
    echo "Network configuration complete:"
    for iface in /sys/class/net/*; do
        name=\$(basename "\$iface")
        [ "\$name" = "lo" ] && continue
        ip=\$(ifconfig "\$name" 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d: -f2)
        [ -n "\$ip" ] && echo "  \$name: \$ip"
    done
    echo ""
    
    return 0
}

# ZFS import
import_zfs() {
    echo "Checking for ZFS pools..."
    if command -v zpool >/dev/null 2>&1; then
        zpool import -a -N 2>/dev/null && echo "Imported ZFS pools" || echo "No ZFS pools found"
    else
        echo "ZFS tools not available"
    fi
}

# Start SSH
start_ssh() {
    echo "Starting SSH server..."
    mkdir -p /var/run/dropbear
    mkdir -p /root/.ssh
    
    # Check for host keys
    if [ ! -f /etc/dropbear/dropbear_rsa_host_key ] && [ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
        echo "WARNING: No SSH host keys found, generating new ones..."
        if command -v dropbearkey >/dev/null 2>&1; then
            dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 2>/dev/null || echo "Failed to generate RSA key"
        fi
    fi
    
    # Start dropbear with:
    # -R = generate host keys if missing
    # -E = log to stderr
    # -s = disable password logins (key-only authentication)
    # -p 22 = listen on port 22
    dropbear -R -E -s -p 22
    echo "SSH running on port 22 (key-only authentication, passwords disabled)"
}

# Main boot sequence
echo "Starting main boot sequence..."

# Load kernel modules
load_modules

# Setup network
if setup_network; then
    # Import ZFS pools  
    import_zfs
    
    # Start SSH
    start_ssh
    
    # Get current IP for display
    current_ip=\$(cat /tmp/obtained_ip 2>/dev/null || ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print \$2}' | head -1 | sed 's/addr://')
    
    echo ""
    echo "=== ZFS Installation System Ready ==="
    echo "IP Address: \$current_ip"
    echo "SSH: ssh root@\$current_ip"
    echo ""
    echo "SECURITY NOTE:"
    echo "  Password authentication is DISABLED. You must use the SSH key"
    echo "  that was packaged into this initramfs during build."
    echo "  (Same key you used to build create-ram-os.sh)"
    echo ""
    echo "Available tools:"
    echo "  - Disk: sgdisk, parted, mkfs.fat, mkfs.ext4"
    echo "  - ZFS: zpool, zfs, zdb, zgenhostid"
    echo "  - Package: apt, dpkg, debootstrap"
    echo "  - Download: curl, wget, rsync"
    echo "  - System: udevadm, systemctl, resolvectl"
    echo "  - UI: whiptail"
    echo ""
    echo "Installation script: /root/install_os.sh"
    echo "Run: /root/install_os.sh"
    echo ""
else
    echo "Network setup failed"
fi

# CRITICAL: Keep init process alive forever
echo ""
echo "System is running. Use 'poweroff' or 'reboot' command to shutdown."
echo "Init process will stay running to prevent kernel panic."

# Safe shutdown function
do_shutdown() {
    echo ""
    echo "=== Shutting down ==="
    echo "Syncing filesystems..."
    sync
    
    # Unmount all filesystems except essential ones
    echo "Unmounting filesystems..."
    # Get list of mounted filesystems, reverse order, skip essential ones
    for mp in \$(awk '{print \$2}' /proc/mounts | grep -v -E '^/(proc|sys|dev|run|tmp)$' | sort -r); do
        umount "\$mp" 2>/dev/null && echo "  Unmounted \$mp" || true
    done
    
    sync
    echo "Shutdown complete."
}

# Handle shutdown signals
trap 'do_shutdown; reboot -f' SIGTERM SIGINT
trap 'do_shutdown; poweroff -f' SIGUSR1

# Start a shell but keep init running
setsid cttyhack sh &

# Wait forever to prevent init from exiting
while true; do
    sleep 3600
done
EOF

    chmod +x init
    
    # Create safe reboot/poweroff scripts that signal init for proper shutdown
    # These override BusyBox versions which don't work with our minimal init
    print_status "Creating safe reboot/poweroff scripts..."
    
    cat > sbin/reboot << 'REBOOT_SCRIPT'
#!/bin/sh
# Safe reboot for RAM OS - exports ZFS, syncs and unmounts before rebooting
echo "Initiating safe reboot..."
sync

# Export all ZFS pools first (cleanest way to unmount ZFS)
if command -v zpool >/dev/null 2>&1; then
    pools=$(zpool list -H -o name 2>/dev/null)
    if [ -n "$pools" ]; then
        echo "Exporting ZFS pools..."
        for pool in $pools; do
            zpool export "$pool" 2>/dev/null && echo "  Exported pool: $pool" || true
        done
    fi
fi

# Unmount all non-essential filesystems
echo "Unmounting filesystems..."
for mp in $(awk '{print $2}' /proc/mounts | grep -v -E '^/(proc|sys|dev|run|tmp|)$' | sort -r); do
    umount "$mp" 2>/dev/null && echo "  Unmounted $mp" || true
done
sync
echo "Rebooting..."
busybox reboot -f
REBOOT_SCRIPT
    chmod +x sbin/reboot
    
    cat > sbin/poweroff << 'POWEROFF_SCRIPT'
#!/bin/sh
# Safe poweroff for RAM OS - exports ZFS, syncs and unmounts before powering off
echo "Initiating safe poweroff..."
sync

# Export all ZFS pools first (cleanest way to unmount ZFS)
if command -v zpool >/dev/null 2>&1; then
    pools=$(zpool list -H -o name 2>/dev/null)
    if [ -n "$pools" ]; then
        echo "Exporting ZFS pools..."
        for pool in $pools; do
            zpool export "$pool" 2>/dev/null && echo "  Exported pool: $pool" || true
        done
    fi
fi

# Unmount all non-essential filesystems
echo "Unmounting filesystems..."
for mp in $(awk '{print $2}' /proc/mounts | grep -v -E '^/(proc|sys|dev|run|tmp|)$' | sort -r); do
    umount "$mp" 2>/dev/null && echo "  Unmounted $mp" || true
done
sync
echo "Powering off..."
busybox poweroff -f
POWEROFF_SCRIPT
    chmod +x sbin/poweroff
    
    # Also provide halt
    ln -sf poweroff sbin/halt
    
    # Create essential symlinks
    if [ ! -e sbin/init ]; then
        ln -s ../init sbin/init
    fi
    
    # Ensure /bin/bash exists for scripts and as default shell
    if [ ! -e bin/bash ]; then
        if [ -f sbin/bash ]; then
            ln -sf ../sbin/bash bin/bash
        elif [ -f usr/bin/bash ]; then
            ln -sf ../usr/bin/bash bin/bash
        fi
    fi
    # Verify bash exists, fall back to sh if not
    if [ ! -e bin/bash ]; then
        print_warning "bash not found, using /bin/sh as default shell"
        DEFAULT_SHELL="/bin/sh"
    else
        DEFAULT_SHELL="/bin/bash"
    fi
    
    # Create basic etc files (use bash as default shell for proper profile sourcing)
    echo "root:x:0:0:root:/root:$DEFAULT_SHELL" > etc/passwd
    echo "root:x:0:" > etc/group
    echo "127.0.0.1 localhost" > etc/hosts
    
    # Create /etc/shells (required for restricted shells/dropbear)
    echo "/bin/sh" > etc/shells
    echo "/bin/bash" >> etc/shells
    
    # Ensure strict permissions for restricted-login environments
    chmod 700 root
    mkdir -p root/.ssh
    chmod 700 root/.ssh
    
    # Create /etc/profile with environment for SSH sessions
    cat > etc/profile << 'PROFILE'
# Environment for RAM OS
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export LANG=C.utf8
export LC_ALL=C.utf8
export TERM=xterm-256color
export INPUTRC=/etc/inputrc
export NCURSES_NO_UTF8_ACS=1
export LD_LIBRARY_PATH=/lib:/usr/lib:/lib64:/usr/lib64

# Source user profile if exists
[ -f ~/.profile ] && . ~/.profile
PROFILE

    # Create /etc/inputrc for nice readline behavior
    cat > etc/inputrc << 'INPUTRC'
# Allow 8-bit input/output
set meta-flag on
set input-meta on
set output-meta on
set convert-meta off

# Common shortcuts
"\e[5~": history-search-backward
"\e[6~": history-search-forward
"\e[3~": delete-char
"\e[2~": quoted-insert
"\e[A": history-search-backward
"\e[B": history-search-forward
INPUTRC

    # Create /root/.bashrc for nice prompt and aliases
    cat > root/.bashrc << 'BASHRC'
# Source global definitions
if [ -f /etc/bash.bashrc ]; then
    . /etc/bash.bashrc
fi

# Enable color support
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi

# Nice colored prompt
# [green user]@[blue host]:[yellow path] $
export PS1='\[\033[01;32m\]\u@ram-os\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias install='/root/install_os.sh'
BASHRC
    
    # Note: SSH authorized_keys will be injected during deployment, not at build time

    # Create initramfs with zstd compression (fast and good ratio)
    print_status "Creating initramfs image with zstd compression..."
    find . | cpio -H newc -o 2>/dev/null | zstd -19 > "$CUSTOM_INITRAMFS"
    
    local size=$(du -h "$CUSTOM_INITRAMFS" | cut -f1)
    print_status "Minimal initramfs created: $CUSTOM_INITRAMFS ($size)"
    
    # Cleanup
    cd /
    rm -rf "$temp_dir"
}

# Test initramfs
test_initramfs() {
    print_status "Testing initramfs..."
    
    local test_dir=$(mktemp -d)
    if zstdcat "$CUSTOM_INITRAMFS" | cpio -id -D "$test_dir" >/dev/null 2>&1; then
        cd "$test_dir"
        
        echo "Essential components:"
        [ -f init ] && [ -x init ] && echo "OK init script" || echo "X init script"
        [ -f bin/busybox ] && [ -x bin/busybox ] && echo "OK busybox" || echo "X busybox"
        [ -f usr/bin/dropbear ] && [ -x usr/bin/dropbear ] && echo "OK dropbear" || echo "X dropbear"
        [ -f etc/dropbear/dropbear_rsa_host_key ] && echo "OK SSH host key" || echo "X SSH host key"
        
        # Test busybox functionality
        if [ -x bin/busybox ]; then
            echo "BusyBox applets: $(./bin/busybox --list | wc -l) available"
        fi
        
        cd /
        rm -rf "$test_dir"
        print_status "Initramfs test completed"
        return 0
    else
        print_error "Failed to extract initramfs"
        rm -rf "$test_dir"
        return 1
    fi
}

# Load with kexec
load_kexec() {
    if ! test_initramfs; then
        print_error "Initramfs test failed"
        return 1
    fi
    
    print_status "Loading kernel with kexec..."
    
    kexec -l "$KERNEL_IMAGE" \
        --initrd="$CUSTOM_INITRAMFS" \
        --append="console=ttyS0,115200n8 console=tty0 rdinit=/init rw quiet"
    
    if [ $? -eq 0 ]; then
        print_status "Kernel loaded successfully"
        return 0
    else
        print_error "Failed to load kernel"
        return 1
    fi
}

# Main execution
main() {
    check_dependencies
    create_minimal_initramfs
    
    # Create self-extracting installer
    print_status "Creating self-extracting installer..."
    print_status "Kernel: $KERNEL_IMAGE"
    print_status "Initramfs: $CUSTOM_INITRAMFS"
    
    local INSTALLER_OUTPUT="/tmp/zfs-ram-boot.sh"
    
    # Create the installer script header with pre-flight checks
    cat > "$INSTALLER_OUTPUT" << 'INSTALLER_HEADER'
#!/bin/bash
# ZFS RAM Boot - Self-Extracting Installer
# Boots system into RAM for ZFS installation

set -e

echo "=== ZFS RAM Boot Installer ==="
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "[!] ERROR: Must run as root"
    echo "    Usage: sudo $0"
    exit 1
fi

# Check kexec availability - will extract from bundle if not on system
KEXEC_CMD=""
if command -v kexec &>/dev/null; then
    KEXEC_CMD="kexec"
    echo "[OK] kexec available (system)"
else
    echo "[!] kexec not found on system, will extract from bundle"
fi


# Check Secure Boot status
if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    if echo "$SB_STATE" | grep -q "enabled"; then
        echo "[!] WARNING: Secure Boot is ENABLED"
        echo "    kexec may fail. Consider disabling Secure Boot in BIOS."
        read -p "    Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "[OK] Secure Boot: disabled or not applicable"
    fi
else
    echo "[?] Cannot check Secure Boot status (mokutil not installed)"
fi

# Check lockdown mode
if [ -f /sys/kernel/security/lockdown ]; then
    LOCKDOWN=$(cat /sys/kernel/security/lockdown 2>/dev/null)
    # Check if lockdown is active (mode in brackets is NOT [none])
    if echo "$LOCKDOWN" | grep -q '\[integrity\]\|\[confidentiality\]'; then
        echo "[!] WARNING: Kernel lockdown is ACTIVE: $LOCKDOWN"
        echo "    kexec may be restricted. Trying anyway..."
    else
        echo "[OK] Kernel lockdown: none"
    fi
else
    echo "[OK] Kernel lockdown: not present"
fi

# Check available memory
MEM_AVAILABLE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_AVAILABLE" -lt 500 ]; then
    echo "[!] WARNING: Low memory available: ${MEM_AVAILABLE}MB"
    echo "    Recommend at least 500MB free"
fi
echo "[OK] Available memory: ${MEM_AVAILABLE}MB"

echo ""
echo "Pre-flight checks passed. Extracting..."

# Extract archive from this script
ARCHIVE_START=$(awk '/^__ARCHIVE_START__$/{print NR + 1; exit 0;}' "$0")
TEMP_DIR=$(mktemp -d)
tail -n +$ARCHIVE_START "$0" | tar -xf - -C "$TEMP_DIR"

cd "$TEMP_DIR"

# Find kernel and initramfs
KERNEL=$(ls vmlinuz-* 2>/dev/null | head -1)
INITRAMFS=$(ls minimal-ram-system.img 2>/dev/null | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRAMFS" ]; then
    echo "[!] ERROR: Could not find kernel or initramfs in archive"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[OK] Kernel: $KERNEL"
echo "[OK] Initramfs: $INITRAMFS"

# Inject SSH host keys from this server into initramfs
echo ""
echo "Injecting SSH host keys from this server..."

# Unpack initramfs once - use for extracting tools and repacking with keys
echo "[+] Unpacking initramfs for SSH key injection..."
INITRAMFS_DIR=$(mktemp -d)
(cd "$INITRAMFS_DIR" && zstdcat "$TEMP_DIR/$INITRAMFS" | cpio -idm 2>/dev/null)

# If system kexec not available, extract from unpacked initramfs
if [ -z "$KEXEC_CMD" ]; then
    if [ -f "$INITRAMFS_DIR/sbin/kexec" ]; then
        # Copy to /tmp (outside TEMP_DIR) so TEMP_DIR can be safely deleted
        cp "$INITRAMFS_DIR/sbin/kexec" /tmp/kexec_embedded
        chmod +x /tmp/kexec_embedded
        KEXEC_CMD="/tmp/kexec_embedded"
        echo "[OK] kexec extracted from bundle"
    else
        echo "[!] ERROR: kexec not available and not found in bundle"
        echo "    Install kexec-tools on build machine to embed kexec in bundle"
        rm -rf "$INITRAMFS_DIR" "$TEMP_DIR"
        exit 1
    fi
fi

# Set up dropbearconvert - use system or extracted from initramfs
DROPBEARCONVERT_CMD=""
if command -v dropbearconvert &>/dev/null; then
    DROPBEARCONVERT_CMD="dropbearconvert"
elif [ -f "$INITRAMFS_DIR/usr/bin/dropbearconvert" ]; then
    export LD_LIBRARY_PATH="$INITRAMFS_DIR/lib/x86_64-linux-gnu:$INITRAMFS_DIR/usr/lib/x86_64-linux-gnu:$INITRAMFS_DIR/lib:$INITRAMFS_DIR/lib64:$INITRAMFS_DIR/usr/lib:$INITRAMFS_DIR/usr/lib64:$LD_LIBRARY_PATH"
    DROPBEARCONVERT_CMD="$INITRAMFS_DIR/usr/bin/dropbearconvert"
    chmod +x "$DROPBEARCONVERT_CMD"
    echo "[OK] Using dropbearconvert from initramfs"
else
    echo "[!] WARNING: dropbearconvert not found"
fi

KEYS_INJECTED=0

# Convert OpenSSH keys to Dropbear format (directly into initramfs dir)
if [ -n "$DROPBEARCONVERT_CMD" ] && [ -d /etc/ssh ]; then
    mkdir -p "$INITRAMFS_DIR/etc/dropbear"
    
    # Ed25519 (preferred)
    if [ -f /etc/ssh/ssh_host_ed25519_key ]; then
        if "$DROPBEARCONVERT_CMD" openssh dropbear /etc/ssh/ssh_host_ed25519_key \
            "$INITRAMFS_DIR/etc/dropbear/dropbear_ed25519_host_key" 2>/dev/null; then
            echo "[OK] Converted Ed25519 host key"
            KEYS_INJECTED=$((KEYS_INJECTED + 1))
        fi
    fi
    
    # ECDSA
    if [ -f /etc/ssh/ssh_host_ecdsa_key ]; then
        if "$DROPBEARCONVERT_CMD" openssh dropbear /etc/ssh/ssh_host_ecdsa_key \
            "$INITRAMFS_DIR/etc/dropbear/dropbear_ecdsa_host_key" 2>/dev/null; then
            echo "[OK] Converted ECDSA host key"
            KEYS_INJECTED=$((KEYS_INJECTED + 1))
        fi
    fi
    
    # RSA (fallback)
    if [ -f /etc/ssh/ssh_host_rsa_key ]; then
        if "$DROPBEARCONVERT_CMD" openssh dropbear /etc/ssh/ssh_host_rsa_key \
            "$INITRAMFS_DIR/etc/dropbear/dropbear_rsa_host_key" 2>/dev/null; then
            echo "[OK] Converted RSA host key"
            KEYS_INJECTED=$((KEYS_INJECTED + 1))
        fi
    fi
fi

if [ $KEYS_INJECTED -eq 0 ]; then
    echo "[!] WARNING: No SSH keys converted, generating new ones..."
    # Try to use dropbearkey from initramfs or system
    DROPBEARKEY_CMD=""
    if command -v dropbearkey &>/dev/null; then
        DROPBEARKEY_CMD="dropbearkey"
    elif [ -f "$INITRAMFS_DIR/usr/bin/dropbearkey" ]; then
        DROPBEARKEY_CMD="$INITRAMFS_DIR/usr/bin/dropbearkey"
        chmod +x "$DROPBEARKEY_CMD"
    fi
    
    if [ -n "$DROPBEARKEY_CMD" ]; then
        mkdir -p "$INITRAMFS_DIR/etc/dropbear"
        "$DROPBEARKEY_CMD" -t ed25519 -f "$INITRAMFS_DIR/etc/dropbear/dropbear_ed25519_host_key" 2>/dev/null && \
            echo "[OK] Generated Ed25519 host key" || true
    fi
else
    echo "[OK] Injected $KEYS_INJECTED SSH host key(s) from this server"
fi

# Repack initramfs with injected keys and DNS config
echo "Repacking initramfs with SSH keys and DNS config..."

# Get actual DNS servers from host (resolvectl knows the real ones even with systemd-resolved)
echo "Configuring DNS for RAM OS..."
if command -v resolvectl &>/dev/null; then
    # Get DNS servers from resolvectl (works even when /etc/resolv.conf points to systemd stub)
    DNS_SERVERS=$(resolvectl dns 2>/dev/null | awk '
        /^Global:/ { for(i=2; i<=NF; i++) print $i }
    ' | head -3)
    
    # If Global is empty, try first non-empty link
    if [ -z "$DNS_SERVERS" ]; then
        DNS_SERVERS=$(resolvectl dns 2>/dev/null | awk '
            /^Link [0-9]+ / && NF > 3 { for(i=4; i<=NF; i++) print $i; exit }
        ')
    fi
    
    if [ -n "$DNS_SERVERS" ]; then
        echo "$DNS_SERVERS" | while read -r dns; do
            echo "nameserver $dns"
        done > "$INITRAMFS_DIR/etc/resolv.conf"
        echo "[OK] DNS servers from resolvectl: $(echo $DNS_SERVERS | tr '\n' ' ')"
    else
        # Fallback to public DNS
        cat > "$INITRAMFS_DIR/etc/resolv.conf" << 'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
DNSEOF
        echo "[!] No DNS from resolvectl, using public DNS"
    fi
else
    # No resolvectl available, use public DNS
    cat > "$INITRAMFS_DIR/etc/resolv.conf" << 'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
DNSEOF
    echo "[!] resolvectl not available, using public DNS servers"
fi

# ===== SSH Public Key Selection =====
echo ""
echo "Configuring SSH access for RAM OS..."
mkdir -p "$INITRAMFS_DIR/root/.ssh"
chmod 700 "$INITRAMFS_DIR/root/.ssh"

# Check if whiptail is available
USE_WHIPTAIL=false
if command -v whiptail >/dev/null 2>&1; then
    USE_WHIPTAIL=true
fi

# Collect available SSH keys from common locations
SSH_KEYS_FILE=$(mktemp)
KEY_INDEX=0

# Build list of unique authorized_keys files (avoid duplicates when ~ == /root)
AUTH_FILES=""
for auth_file in /root/.ssh/authorized_keys ~/.ssh/authorized_keys; do
    # Resolve to absolute path and check if already seen
    if [ -f "$auth_file" ]; then
        abs_path=$(readlink -f "$auth_file" 2>/dev/null || echo "$auth_file")
        if ! echo "$AUTH_FILES" | grep -qF "$abs_path"; then
            AUTH_FILES="$AUTH_FILES $abs_path"
        fi
    fi
done

for auth_file in $AUTH_FILES; do
    if [ -f "$auth_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [ -z "$line" ] && continue
            case "$line" in \#*) continue ;; esac
            
            # Extract key type (first field)
            key_type=$(echo "$line" | awk '{print $1}') || true
            # Count fields to determine if there's a comment
            field_count=$(echo "$line" | awk '{print NF}') || true
            
            if [ "$field_count" -gt 2 ]; then
                # Has a comment (3+ fields) - use the comment
                key_comment=$(echo "$line" | cut -d' ' -f3-)
            else
                # No comment - generate fingerprint preview
                set +e
                key_fp=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | cut -c1-16)
                set -e
                if [ -n "$key_fp" ]; then
                    key_comment="$key_type ($key_fp...)"
                else
                    key_comment="$key_type key"
                fi
            fi
            
            # Truncate comment if too long for whiptail
            key_comment=$(echo "$key_comment" | cut -c1-50)
            
            KEY_INDEX=$((KEY_INDEX + 1))
            echo "$KEY_INDEX|$key_comment|$line" >> "$SSH_KEYS_FILE"
        done < "$auth_file"
    fi
done

# Build whiptail menu options
MENU_OPTIONS=""
if [ -s "$SSH_KEYS_FILE" ]; then
    while IFS='|' read -r idx comment fullkey; do
        MENU_OPTIONS="$MENU_OPTIONS $idx \"$comment\" OFF"
    done < "$SSH_KEYS_FILE"
fi
MENU_OPTIONS="$MENU_OPTIONS NEW \"Generate new SSH keypair\" OFF"

if [ "$USE_WHIPTAIL" = "true" ]; then
    # Set whiptail colors (green on black terminal theme)
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
    
    # Show whiptail radiolist for key selection (single selection only)
    # Use a temp script to properly handle the dynamic arguments and fd redirection
    WHIPTAIL_SCRIPT=$(mktemp)
    cat > "$WHIPTAIL_SCRIPT" << WHIPTAIL_EOF
#!/bin/bash
whiptail --title "SSH Key Selection" \
    --radiolist "Select SSH public key to authorize for RAM OS access.\nPassword authentication is DISABLED.\n\nSelect one key or generate a new one:" \
    20 78 10 \
    $MENU_OPTIONS \
    3>&1 1>&2 2>&3
WHIPTAIL_EOF
    chmod +x "$WHIPTAIL_SCRIPT"
    
    set +e
    SELECTED=$("$WHIPTAIL_SCRIPT")
    WHIPTAIL_EXIT=$?
    set -e
    rm -f "$WHIPTAIL_SCRIPT"
else
    # Text-based fallback when whiptail is not available
    echo ""
    echo "========================================="
    echo "   SSH Key Selection for RAM OS Access"
    echo "========================================="
    echo ""
    echo "Password authentication is DISABLED."
    echo "Select SSH public key(s) to authorize:"
    echo ""
    
    if [ -s "$SSH_KEYS_FILE" ]; then
        while IFS='|' read -r idx comment fullkey; do
            echo "  [$idx] $comment"
        done < "$SSH_KEYS_FILE"
    fi
    echo "  [NEW] Generate new SSH keypair"
    echo ""
    echo "Enter selection(s) separated by spaces (e.g., '1 2' or 'NEW'):"
    printf "> "
    read SELECTED
fi

if [ -z "$SELECTED" ]; then
    echo "[!] ERROR: No SSH key selected. Cannot continue without SSH access."
    echo "[!] RAM OS has password authentication disabled."
    rm -f "$SSH_KEYS_FILE"
    rm -rf "$INITRAMFS_DIR"
    exit 1
fi

# Process selected keys
AUTHORIZED_KEYS=""
GENERATE_NEW=false

for selection in $SELECTED; do
    selection=$(echo "$selection" | tr -d '"')
    if [ "$selection" = "NEW" ]; then
        GENERATE_NEW=true
    else
        # Find the full key by index
        fullkey=$(grep "^$selection|" "$SSH_KEYS_FILE" | cut -d'|' -f3)
        if [ -n "$fullkey" ]; then
            AUTHORIZED_KEYS="$AUTHORIZED_KEYS$fullkey
"
        fi
    fi
done

# Generate new keypair if requested
if [ "$GENERATE_NEW" = "true" ]; then
    echo ""
    echo "Generating new Ed25519 SSH keypair..."
    NEW_KEY_DIR=$(mktemp -d)
    ssh-keygen -t ed25519 -f "$NEW_KEY_DIR/ram_os_key" -N "" -C "ram-os-access-$(date +%Y%m%d)" >/dev/null 2>&1
    
    NEW_PUBKEY=$(cat "$NEW_KEY_DIR/ram_os_key.pub")
    NEW_PRIVKEY=$(cat "$NEW_KEY_DIR/ram_os_key")
    AUTHORIZED_KEYS="$AUTHORIZED_KEYS$NEW_PUBKEY
"
    
    # Display private key with warning
    clear
    echo ""
    echo "+==============================================================================+"
    echo "|                        !!  IMPORTANT - SAVE THIS KEY  !!                     |"
    echo "+==============================================================================+"
    echo "|                                                                              |"
    echo "|  A new SSH keypair has been generated for RAM OS access.                     |"
    echo "|  Password authentication is DISABLED.                                        |"
    echo "|                                                                              |"
    echo "|  WITHOUT THIS PRIVATE KEY, YOU CANNOT ACCESS THE RAM OS!                     |"
    echo "|                                                                              |"
    echo "+==============================================================================+"
    echo ""
    echo "--- BEGIN PRIVATE KEY (save to a file, e.g. ~/.ssh/ram_os_key) ---"
    echo ""
    echo "$NEW_PRIVKEY"
    echo ""
    echo "--- END PRIVATE KEY ---"
    echo ""
    echo "After saving the key, set permissions with: chmod 600 ~/.ssh/ram_os_key"
    echo "Then connect with: ssh -i ~/.ssh/ram_os_key root@<server-ip>"
    echo ""
    
    # Wait for user confirmation
    echo "Press ENTER after you have saved the private key to continue..."
    read _
    
    # Cleanup
    rm -rf "$NEW_KEY_DIR"
fi

rm -f "$SSH_KEYS_FILE"

# Write authorized_keys to initramfs
echo "$AUTHORIZED_KEYS" > "$INITRAMFS_DIR/root/.ssh/authorized_keys"
chmod 600 "$INITRAMFS_DIR/root/.ssh/authorized_keys"
# Count non-empty lines as key count
KEY_COUNT=$(echo "$AUTHORIZED_KEYS" | grep -v '^$' | wc -l)
echo "[OK] Configured SSH public key for RAM OS access"

# ===== Network Configuration Capture (All Interfaces) =====
echo ""
echo "Capturing network configuration for all interfaces..."

# Create network config file in initramfs
NETWORK_CONFIG="$INITRAMFS_DIR/etc/network_config.sh"
mkdir -p "$INITRAMFS_DIR/etc"

cat > "$NETWORK_CONFIG" << 'CONFIG_HEADER'
#!/bin/sh
# Auto-generated network configuration for RAM OS
# Mirrors host network setup

# Configure an interface by MAC address
# Usage: configure_iface "MAC" "IP/CIDR" "GATEWAY" "route1" "route2" ...
configure_iface() {
    local target_mac="$1"
    local ip_cidr="$2"
    local gateway="$3"
    shift 3
    
    # Find interface by MAC
    local iface=""
    for iface_path in /sys/class/net/*; do
        [ -d "$iface_path" ] || continue
        local name=$(basename "$iface_path")
        [ "$name" = "lo" ] && continue
        
        local mac=$(cat "$iface_path/address" 2>/dev/null)
        if [ "$mac" = "$target_mac" ]; then
            iface="$name"
            break
        fi
    done
    
    if [ -z "$iface" ]; then
        echo "WARNING: No interface found with MAC $target_mac"
        return 1
    fi
    
    echo "Configuring $iface (MAC: $target_mac)..."
    
    # Parse IP and CIDR
    local ip=$(echo "$ip_cidr" | cut -d/ -f1)
    local cidr=$(echo "$ip_cidr" | cut -d/ -f2)
    
    # Convert CIDR to netmask
    local netmask
    case "$cidr" in
        32) netmask="255.255.255.255" ;;
        31) netmask="255.255.255.254" ;;
        30) netmask="255.255.255.252" ;;
        29) netmask="255.255.255.248" ;;
        28) netmask="255.255.255.240" ;;
        27) netmask="255.255.255.224" ;;
        26) netmask="255.255.255.192" ;;
        25) netmask="255.255.255.128" ;;
        24) netmask="255.255.255.0" ;;
        16) netmask="255.255.0.0" ;;
        8) netmask="255.0.0.0" ;;
        *) netmask="255.255.255.0" ;;
    esac
    
    # Bring interface up and configure IP
    ifconfig "$iface" "$ip" netmask "$netmask" up
    echo "  IP: $ip/$cidr"
    
    # For /32, add host route to gateway first
    if [ "$cidr" = "32" ] && [ -n "$gateway" ]; then
        ip route add "$gateway" dev "$iface" 2>/dev/null || true
    fi
    
    # Add gateway route if specified
    if [ -n "$gateway" ]; then
        ip route add default via "$gateway" dev "$iface" 2>/dev/null || true
        echo "  Gateway: $gateway"
    fi
    
    # Add additional routes
    while [ $# -gt 0 ]; do
        local route="$1"
        shift
        if echo "$route" | grep -q ' via '; then
            local dest=$(echo "$route" | cut -d' ' -f1)
            local via=$(echo "$route" | cut -d' ' -f3)
            ip route add "$dest" via "$via" dev "$iface" 2>/dev/null || true
        else
            ip route add "$route" dev "$iface" 2>/dev/null || true
        fi
        echo "  Route: $route"
    done
    
    return 0
}

# Interface configurations (generated from host)
CONFIG_HEADER

IFACE_COUNT=0

# Iterate through all interfaces with IPv4 addresses
for iface in $(ip -4 addr show | grep -E '^[0-9]+:' | awk -F: '{print $2}' | tr -d ' '); do
    # Skip loopback
    [ "$iface" = "lo" ] && continue
    
    # Get IP for this interface
    iface_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
    [ -z "$iface_ip" ] && continue
    
    # Get MAC address
    iface_mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
    [ -z "$iface_mac" ] && continue
    
    # Get gateway for this interface (default route or first via route)
    iface_gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -1)
    if [ -z "$iface_gw" ]; then
        iface_gw=$(ip route show dev "$iface" 2>/dev/null | grep via | awk '{print $3}' | head -1)
    fi
    
    echo "[OK] $iface: $iface_ip (MAC: $iface_mac)"
    
    # Collect routes for this interface
    routes=""
    while read -r route; do
        # Skip default routes (handled by gateway)
        echo "$route" | grep -q '^default' && continue
        
        # Extract destination and via
        dest=$(echo "$route" | awk '{print $1}')
        if echo "$route" | grep -q 'via'; then
            via=$(echo "$route" | sed -n 's/.*via \([0-9.]*\).*/\1/p')
            routes="$routes \"$dest via $via\""
        elif echo "$route" | grep -q 'scope link'; then
            routes="$routes \"$dest\""
        fi
    done << EOF
$(ip route show dev "$iface" 2>/dev/null)
EOF
    
    # Write configuration call
    echo "configure_iface \"$iface_mac\" \"$iface_ip\" \"$iface_gw\" $routes" >> "$NETWORK_CONFIG"
    
    IFACE_COUNT=$((IFACE_COUNT + 1))
done

chmod +x "$NETWORK_CONFIG"
echo "[OK] Captured configuration for $IFACE_COUNT interface(s)"

echo ""
echo "Repacking initramfs with SSH and network configuration..."
echo "(This may take a moment...)"
(cd "$INITRAMFS_DIR" && find . | cpio -H newc -o 2>/dev/null | zstd -1 > "$TEMP_DIR/$INITRAMFS.new")
mv "$TEMP_DIR/$INITRAMFS.new" "$TEMP_DIR/$INITRAMFS"
rm -rf "$INITRAMFS_DIR"
echo "[OK] Initramfs repacked successfully"
echo ""

# Load kexec with kernel configuration
echo ""
echo "Loading kernel..."
CMDLINE="rdinit=/init rw quiet"
echo "[OK] Kernel cmdline: $CMDLINE"

if ! "$KEXEC_CMD" -l "$KERNEL" --initrd="$INITRAMFS" --append="$CMDLINE" 2>&1; then
    echo ""
    echo "[!] ERROR: kexec load failed"
    echo "    If Secure Boot error, try: kexec -s -l ..."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""
echo "=== Ready to Boot ==="
echo "System will reboot into RAM."
echo "Network: IP will be inherited from this host ($HOST_IP)"
echo "SSH will be available on port 22 (same IP)."
echo ""
printf "Execute kexec now? (y/N): "
read REPLY
echo

case "$REPLY" in
    [Yy]|[Yy][Ee][Ss])
    rm -rf "$TEMP_DIR"
    echo "Booting..."
    "$KEXEC_CMD" -e
    ;;
    *)
    echo "Aborted. To boot manually: $KEXEC_CMD -e"
    echo "Temp files in: $TEMP_DIR"
    ;;
esac

exit 0
__ARCHIVE_START__
INSTALLER_HEADER

    # Append the tar archive to the installer (no compression - initramfs is already zstd-compressed)
    tar -cf - -C /boot "$(basename $KERNEL_IMAGE)" -C /tmp "$(basename $CUSTOM_INITRAMFS)" >> "$INSTALLER_OUTPUT"
    
    chmod +x "$INSTALLER_OUTPUT"
    local installer_size=$(du -h "$INSTALLER_OUTPUT" | cut -f1)
    print_status "Self-extracting installer created: $INSTALLER_OUTPUT ($installer_size)"
    
    if load_kexec; then
        echo ""
        echo "=== SUCCESS ==="
        echo "ZFS RAM system is ready!"
        echo ""
        echo "Kernel version: $KERNEL_VERSION"
        echo ""
        echo "File created:"
        echo "  $INSTALLER_OUTPUT ($installer_size)"
        echo ""
        echo "=== FOR REMOTE DEPLOYMENT ==="
        echo "Upload installer to your file server, then on target:"
        echo "  curl -L -o /tmp/zfs-ram-boot.sh https://your-server.com/zfs-ram-boot.sh"
        echo "  chmod +x /tmp/zfs-ram-boot.sh"
        echo "  sudo /tmp/zfs-ram-boot.sh"
        echo ""
    else
        print_error "Failed to create RAM system"
        exit 1
    fi
}

# Cleanup
cleanup() {
    rm -f "$CUSTOM_INITRAMFS" 2>/dev/null || true
}

trap cleanup EXIT
main "$@"