# RAM OS - ZFS DevOps Toolkit

A self-contained RAM-based operating system that serves as the **ultimate Swiss army knife for DevOps engineers** working with Ubuntu servers and ZFS filesystems.

## 💡 What is RAM OS?

RAM OS boots entirely into memory, freeing your server's disks for any operation you need. Whether you're performing a fresh ZFS root installation, recovering from a failed boot, examining snapshots, or migrating data between servers - RAM OS has you covered.

### Complete ZFS Toolset
- **Full ZFS utilities** - `zpool`, `zfs`, `zdb` for all pool and dataset operations
- **Snapshot management** - Create, list, compare, clone, and rollback snapshots
- **Remote replication** - Send/receive snapshots over SSH for backups and migrations
- **Pool recovery** - Import pools, scrub, repair, and recover data

### Full SSH Stack
- **Dropbear SSH server** - Secure remote access with key-only authentication
- **SSH client** (`dbclient`) - Connect to other servers for replication workflows
- **SFTP server** - Transfer files to/from the RAM OS
- **ssh-keygen** - Generate and manage SSH keys on the fly

### Daily DevOps Operations
- Examine and compare ZFS snapshots before rollback
- Clone datasets for testing without affecting production
- Receive snapshots from remote servers for disaster recovery
- Migrate data between pools or servers
- Repair boot issues without rescue mode dependencies

## 🚀 Features

### RAM OS Builder (`create-ram-os.sh`)
- **Self-extracting bundle** - Incredibly compact (~43MB) single executable containing kernel + initramfs
- **Embedded kexec** - Works on servers without kexec-tools installed
- **SSH key-only access** - No password authentication, maximum security
- **Interactive key selection** - Choose existing SSH keys or generate new ones at deploy time
- **Persistent SSH host keys** - Inject server's original SSH keys to prevent MITM warnings
- **Full network mirroring** - Captures ALL interfaces with IPs, gateways, and routes from host
- **Multi-NIC support** - All network interfaces accessible after boot (SSH on any IP)
- **MAC-based interface detection** - Works with both systemd and legacy interface naming
- **DNS configuration** - Inherits working DNS from host, falls back to public DNS

### Installed Tools

| Category | Tools |
|----------|-------|
| **Shell** | bash, busybox (ash, core utils) |
| **Editors** | nano |
| **Monitoring** | htop |
| **Network** | curl, wget, ip, ifconfig, route |
| **SSH** | dropbear (server), dbclient (client), ssh-keygen, sftp-server |
| **ZFS** | zpool, zfs, zdb (full ZFS management suite) |
| **Storage** | fdisk, parted, gdisk, lsblk |
| **Filesystem** | mkfs.ext4, mkfs.vfat, mount, umount |
| **Archives** | tar, gzip, zstd, zstdcat, cpio |
| **Package Mgmt** | debootstrap, dpkg |
| **Boot** | kexec |

### ZFS Installation Script (`install_os.sh`)
- **Interactive disk selection** with whiptail dialogs
- **Automatic partitioning** - EFI/BIOS boot, ZFS root, optional replicated storage
- **ZFS Boot Menu** - Modern boot experience with snapshot rollback support
- **Ubuntu 24.04 (Noble)** with full ZFS integration
- **Secure defaults** - SSH key-only, minimal packages

### Repair & Rescue Toolkit

RAM OS includes everything needed to diagnose and repair server issues without relying on provider rescue modes:

| Use Case | Tools Available |
|----------|----------------|
| **Disk Diagnostics** | `lsblk`, `blkid`, `fdisk`, `gdisk`, `parted` |
| **Filesystem Repair** | `fsck.ext4`, `zpool scrub`, `zpool clear` |
| **ZFS Recovery** | `zpool import -f`, `zfs rollback`, `zdb` |
| **Data Recovery** | `zfs send/receive`, `rsync`, `tar` |
| **Network Diagnostics** | `ip`, `ifconfig`, `route`, `ping`, `curl` |
| **System Analysis** | `htop`, `dmesg`, `lsmod`, `mount` |

**Common rescue scenarios:**
- Import and repair damaged ZFS pools
- Rollback to previous ZFS snapshots
- Repartition and reinstall without provider intervention
- Transfer data between servers via SSH
- Debug boot issues by examining disk contents

### Safe Shutdown

RAM OS provides safe `reboot`, `poweroff`, and `halt` commands that properly sync and unmount all filesystems:

```
reboot/poweroff/halt
     ↓
1. sync              ← Flush all disk buffers
2. zpool export      ← Export ZFS pools (if any)
3. umount            ← Unmount all filesystems
4. sync              ← Final flush
5. reboot/poweroff   ← Execute action
```

This prevents filesystem corruption even when ZFS pools or other mounts are active.

## 📋 Requirements

### Build System
- Ubuntu/Debian with root access
- Required packages: `busybox-static`, `dropbear-bin`, `kexec-tools`, `zstd`, `debootstrap`
- Internet connection for downloading ZFS Boot Menu

### Target Server
- x86_64 architecture
- EFI or BIOS boot support
- 2GB+ RAM (4GB+ recommended)
- Kernel with kexec support (kexec binary is embedded in bundle)

## 🛠️ Usage

### 1. Build RAM OS Image

```bash
# On your build machine
sudo ./create-ram-os.sh
```

Creates `/tmp/zfs-ram-boot.sh` - a complete self-extracting RAM OS image (~43MB) containing kernel, initramfs, and all tools.

### 2. Deploy to Target Server

```bash
# Copy bundle to target server
scp /tmp/zfs-ram-boot.sh root@server:/tmp/

# SSH to server and execute
ssh root@server
chmod +x /tmp/zfs-ram-boot.sh
/tmp/zfs-ram-boot.sh
```

The bundle will:
1. Extract kernel and initramfs
2. Inject server's SSH host keys
3. Prompt for SSH public key selection
4. Boot into RAM OS via kexec

### 3. Install Ubuntu with ZFS Root

```bash
# After booting into RAM OS, run:
./install_os.sh
# or simply:
install
```

Follow the interactive prompts to configure:
- Target disk
- Hostname
- Root password
- ZFS ARC cache size
- Replicated storage partition size

## 🔐 Security Features

- **No hardcoded credentials** - SSH keys selected at deploy time
- **Key-only SSH** - Password authentication disabled
- **Persistent host keys** - Original server keys inherited through RAM OS to installed system
- **Minimal attack surface** - Only essential tools included

## 📁 Project Structure

```
ram_os/
├── create-ram-os.sh    # RAM OS builder and bundle creator
├── install_os.sh       # ZFS root installation script
└── README.md           # This file
```

## 🔧 Compatibility

| Component | Supported |
|-----------|-----------|
| **Architecture** | x86_64 |
| **Boot Mode** | EFI, BIOS (legacy) |
| **Target OS** | Ubuntu 24.04 LTS (Noble) |
| **Filesystems** | ZFS (root), FAT32 (EFI), ext4 |
| **Cloud Providers** | Hetzner, OVH, Scaleway, any with kexec |

## 🐛 Troubleshooting

### SSH connection refused after boot
- Ensure you selected/generated an SSH key during deployment
- Check the IP address - it should be the same as before boot

### ZFS mount fails
- Verify kernel modules are loaded: `lsmod | grep zfs`
- Check ZFS status: `zpool status`

### Network not working
- The IP configuration is inherited from the host
- Check `ip addr` and `ip route` for proper configuration

## 📄 License

MIT License - see [LICENSE](LICENSE) file.

Copyright (c) 2026 Andrey Prokopenko <job@terem.fr>

## 🙏 Acknowledgments

- ZFS on Linux team
- ZFS Boot Menu project
- Ubuntu/Canonical
