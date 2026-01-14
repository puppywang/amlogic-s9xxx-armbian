#!/bin/bash
#==========================================================================
# Description: Update kernel from puppywang/kernel release
# Supports both:
#   - Running on target device directly
#   - Running on host machine with TF card mounted via USB adapter
#
# Usage: update-kernel.sh [options]
#   -m, --mount <path>   : Mount point of TF card (e.g., /mnt/tfcard)
#   -v, --version <ver>  : Kernel version (e.g., 6.12.63), default: latest
#   -d, --device <dev>   : Auto-mount device (e.g., /dev/sdb)
#   -H, --headers        : Also install kernel headers (for module compilation)
#   -h, --help           : Show this help message
#
# Examples:
#   # On target device (auto-detect)
#   update-kernel.sh
#
#   # On host machine with TF card mounted
#   update-kernel.sh -m /mnt/tfcard
#
#   # On host machine, auto-mount TF card
#   update-kernel.sh -d /dev/sdb
#==========================================================================

set -e

REPO="puppywang/kernel"
RELEASE_TAG="kernel_stable"
DOWNLOAD_DIR="/tmp/kernel-update"

# Default values
MOUNT_POINT=""
VERSION=""
DEVICE=""
AUTO_UNMOUNT=false
INSTALL_HEADERS=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

show_help() {
    head -25 "$0" | tail -20
    exit 0
}

cleanup() {
    if [[ "$AUTO_UNMOUNT" == "true" && -n "$MOUNT_POINT" ]]; then
        log_info "Unmounting ${MOUNT_POINT}..."
        umount "${MOUNT_POINT}/boot" 2>/dev/null || true
        umount "${MOUNT_POINT}" 2>/dev/null || true
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
    rm -rf "${DOWNLOAD_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mount)
            MOUNT_POINT="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -d|--device)
            DEVICE="$2"
            shift 2
            ;;
        -H|--headers)
            INSTALL_HEADERS=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Determine target paths
if [[ -n "$DEVICE" ]]; then
    # Auto-mount device
    log_info "Auto-mounting device: ${DEVICE}"
    MOUNT_POINT="/tmp/tfcard-$$"
    mkdir -p "${MOUNT_POINT}"
    AUTO_UNMOUNT=true
    
    # Detect partition layout
    # Armbian typically has:
    #   partition 1: boot (ext4 or fat32)
    #   partition 2: rootfs (ext4)
    # Or single partition with /boot inside rootfs
    
    ROOTFS_PART="${DEVICE}2"
    BOOT_PART="${DEVICE}1"
    
    # Check if partitions exist (handle nvme style: p1, p2)
    if [[ ! -b "$ROOTFS_PART" ]]; then
        ROOTFS_PART="${DEVICE}p2"
        BOOT_PART="${DEVICE}p1"
    fi
    
    if [[ ! -b "$ROOTFS_PART" ]]; then
        # Single partition setup
        ROOTFS_PART="${DEVICE}1"
        [[ ! -b "$ROOTFS_PART" ]] && ROOTFS_PART="${DEVICE}p1"
        BOOT_PART=""
    fi
    
    log_info "Mounting rootfs: ${ROOTFS_PART} -> ${MOUNT_POINT}"
    mount "${ROOTFS_PART}" "${MOUNT_POINT}"
    
    # Check if separate boot partition
    if [[ -n "$BOOT_PART" && -b "$BOOT_PART" && ! -d "${MOUNT_POINT}/boot/dtb" ]]; then
        log_info "Mounting boot: ${BOOT_PART} -> ${MOUNT_POINT}/boot"
        mkdir -p "${MOUNT_POINT}/boot"
        mount "${BOOT_PART}" "${MOUNT_POINT}/boot" 2>/dev/null || true
    fi
fi

# Determine boot and lib paths
if [[ -n "$MOUNT_POINT" ]]; then
    # Running on host with mounted TF card
    # Detect if mount point is boot partition or rootfs
    if [[ -f "${MOUNT_POINT}/boot.scr" || -f "${MOUNT_POINT}/armbianEnv.txt" ]]; then
        # Mount point is the boot partition itself
        BOOT_PATH="${MOUNT_POINT}"
        # Try to find rootfs partition (usually next to BOOT in /media)
        PARENT_DIR=$(dirname "${MOUNT_POINT}")
        if [[ -d "${PARENT_DIR}/ROOTFS/lib" ]]; then
            LIB_PATH="${PARENT_DIR}/ROOTFS"
        elif [[ -d "${PARENT_DIR}/rootfs/lib" ]]; then
            LIB_PATH="${PARENT_DIR}/rootfs"
        else
            LIB_PATH="${MOUNT_POINT}"
            log_warn "Could not find rootfs partition, modules will not be installed"
        fi
        log_info "Target mode: Boot partition directly mounted at ${MOUNT_POINT}"
    else
        # Mount point is rootfs with boot inside
        BOOT_PATH="${MOUNT_POINT}/boot"
        LIB_PATH="${MOUNT_POINT}"
        log_info "Target mode: Host machine with TF card mounted at ${MOUNT_POINT}"
    fi
else
    # Running on target device
    BOOT_PATH="/boot"
    LIB_PATH="/"
    log_info "Target mode: Running on target device"
fi

# Verify paths exist
if [[ ! -d "$BOOT_PATH" ]]; then
    log_error "Boot path not found: ${BOOT_PATH}"
    log_error "Please specify mount point with -m or device with -d"
    exit 1
fi

log_debug "BOOT_PATH: ${BOOT_PATH}"
log_debug "LIB_PATH: ${LIB_PATH}"

# Get kernel version from argument or find latest
if [[ -z "$VERSION" ]]; then
    log_info "Fetching latest kernel version from release..."
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}")
    VERSION=$(echo "$RELEASE_JSON" | grep -oP '"name":\s*"\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.gz")' | head -1)
    
    if [[ -z "$VERSION" ]]; then
        log_error "Failed to determine kernel version from release"
        exit 1
    fi
    
    # Get asset (tar.gz file) update time instead of release publish time
    # This reflects when the kernel package was last updated, not when the release was created
    ASSET_TIME=$(echo "$RELEASE_JSON" | grep -A5 "\"name\": \"${VERSION}.tar.gz\"" | grep -oP '"updated_at":\s*"\K[^"]+' | head -1)
    if [[ -n "$ASSET_TIME" ]]; then
        ASSET_TIME_LOCAL=$(date -d "$ASSET_TIME" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "$ASSET_TIME")
    fi
else
    # If version specified manually, fetch release info for time
    log_info "Fetching release info..."
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}" 2>/dev/null || true)
    ASSET_TIME=$(echo "$RELEASE_JSON" | grep -A5 "\"name\": \"${VERSION}.tar.gz\"" | grep -oP '"updated_at":\s*"\K[^"]+' | head -1)
    if [[ -n "$ASSET_TIME" ]]; then
        ASSET_TIME_LOCAL=$(date -d "$ASSET_TIME" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "$ASSET_TIME")
    fi
fi

if [[ -n "$ASSET_TIME_LOCAL" ]]; then
    log_info "Target kernel version: ${VERSION} (updated: ${ASSET_TIME_LOCAL})"
else
    log_info "Target kernel version: ${VERSION}"
fi

# Create download directory
mkdir -p "${DOWNLOAD_DIR}"

# Download kernel package
KERNEL_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${VERSION}.tar.gz"
KERNEL_FILE="${DOWNLOAD_DIR}/${VERSION}.tar.gz"

log_info "Downloading kernel from: ${KERNEL_URL}"
if ! curl -fSL --progress-bar -o "${KERNEL_FILE}" "${KERNEL_URL}"; then
    log_error "Failed to download kernel package"
    exit 1
fi

log_info "Download complete: $(du -h ${KERNEL_FILE} | cut -f1)"

# Extract kernel package
log_info "Extracting kernel package..."
cd "${DOWNLOAD_DIR}"
tar -xzf "${VERSION}.tar.gz"

# List extracted contents for debugging
log_debug "Extracted contents:"
ls -la "${DOWNLOAD_DIR}/"

# Find the actual tar files inside (ophub kernel package structure)
BOOT_TAR=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "boot-*.tar.gz" 2>/dev/null | head -1)
MODULES_TAR=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "modules-*.tar.gz" 2>/dev/null | head -1)
# Prefer rockchip DTB for RK3399/RK3588 boards, fallback to any DTB
DTB_TAR=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "dtb-rockchip-*.tar.gz" 2>/dev/null | head -1)
if [[ -z "$DTB_TAR" ]]; then
    DTB_TAR=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "dtb-*.tar.gz" 2>/dev/null | head -1)
fi

log_debug "BOOT_TAR: ${BOOT_TAR}"
log_debug "MODULES_TAR: ${MODULES_TAR}"
log_debug "DTB_TAR: ${DTB_TAR}"

# Display kernel build time from package
if [[ -n "$BOOT_TAR" && -f "$BOOT_TAR" ]]; then
    # Get build time from the tarball's internal file timestamps
    BUILD_TIME=$(tar -tvzf "$BOOT_TAR" 2>/dev/null | head -1 | awk '{print $4, $5}')
    if [[ -n "$BUILD_TIME" ]]; then
        log_info "Kernel build time: ${BUILD_TIME}"
    fi
fi

# Also check sha256sums file if exists (contains build date in ophub format)
SHA256_FILE=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "sha256sums" 2>/dev/null | head -1)
if [[ -n "$SHA256_FILE" && -f "$SHA256_FILE" ]]; then
    log_debug "Found sha256sums: ${SHA256_FILE}"
    log_debug "Package checksums:"
    cat "$SHA256_FILE" | while read line; do
        log_debug "  $line"
    done
fi

# Backup current kernel (only if backup dir is writable)
BACKUP_DIR="${BOOT_PATH}/backup"
mkdir -p "${BACKUP_DIR}" 2>/dev/null || true
if [[ -d "${BACKUP_DIR}" ]]; then
    log_info "Backing up current kernel..."
    for f in "${BOOT_PATH}"/vmlinuz-* "${BOOT_PATH}"/uInitrd; do
        [[ -f "$f" ]] && cp "$f" "${BACKUP_DIR}/" 2>/dev/null || true
    done
fi

# Install boot files
if [[ -n "$BOOT_TAR" && -f "$BOOT_TAR" ]]; then
    log_info "Installing boot files from: $(basename ${BOOT_TAR})"
    tar -xzf "$BOOT_TAR" -C "${BOOT_PATH}"
else
    log_warn "No boot tarball found, looking for files directly..."
    # Look for individual files
    for f in $(find "${DOWNLOAD_DIR}" -name "vmlinuz-*" -o -name "config-*" -o -name "System.map-*" 2>/dev/null); do
        log_info "Copying: $(basename $f)"
        cp "$f" "${BOOT_PATH}/"
    done
fi

# Install DTB files
if [[ -n "$DTB_TAR" && -f "$DTB_TAR" ]]; then
    log_info "Installing DTB files from: $(basename ${DTB_TAR})"
    mkdir -p "${BOOT_PATH}/dtb/rockchip"
    
    # Extract DTB tar to a temp location first to handle various layouts
    DTB_EXTRACT_DIR="${DOWNLOAD_DIR}/dtb-extract"
    mkdir -p "${DTB_EXTRACT_DIR}"
    tar -xzf "$DTB_TAR" -C "${DTB_EXTRACT_DIR}"
    
    # Check if DTB files are in rockchip subdirectory or at root
    if [[ -d "${DTB_EXTRACT_DIR}/rockchip" ]]; then
        # DTB files are in rockchip/ subdirectory
        cp -f "${DTB_EXTRACT_DIR}/rockchip"/*.dtb "${BOOT_PATH}/dtb/rockchip/" 2>/dev/null || true
    else
        # DTB files are at root level, move them to rockchip/
        cp -f "${DTB_EXTRACT_DIR}"/*.dtb "${BOOT_PATH}/dtb/rockchip/" 2>/dev/null || true
    fi
    
    # Handle overlay directory if exists
    if [[ -d "${DTB_EXTRACT_DIR}/overlay" ]]; then
        log_info "Installing DTB overlay files..."
        mkdir -p "${BOOT_PATH}/dtb/overlay"
        cp -f "${DTB_EXTRACT_DIR}/overlay"/*.dtbo "${BOOT_PATH}/dtb/overlay/" 2>/dev/null || true
    elif [[ -d "${DTB_EXTRACT_DIR}/rockchip/overlay" ]]; then
        log_info "Installing DTB overlay files..."
        mkdir -p "${BOOT_PATH}/dtb/overlay"
        cp -f "${DTB_EXTRACT_DIR}/rockchip/overlay"/*.dtbo "${BOOT_PATH}/dtb/overlay/" 2>/dev/null || true
    fi
    
    rm -rf "${DTB_EXTRACT_DIR}"
else
    # Look for DTB in boot tar or extracted directory
    DTB_DIR=$(find "${DOWNLOAD_DIR}" -type d -name "rockchip" 2>/dev/null | head -1)
    if [[ -n "$DTB_DIR" ]]; then
        log_info "Copying DTB files from: ${DTB_DIR}"
        mkdir -p "${BOOT_PATH}/dtb/rockchip"
        cp -f "${DTB_DIR}"/*.dtb "${BOOT_PATH}/dtb/rockchip/" 2>/dev/null || true
        # Copy overlays if they exist
        if [[ -d "${DTB_DIR}/overlay" ]]; then
            log_info "Copying DTB overlay files..."
            mkdir -p "${BOOT_PATH}/dtb/overlay"
            cp -f "${DTB_DIR}/overlay"/*.dtbo "${BOOT_PATH}/dtb/overlay/" 2>/dev/null || true
        fi
    fi
fi

# Install kernel modules
if [[ -n "$MODULES_TAR" && -f "$MODULES_TAR" ]]; then
    log_info "Installing kernel modules from: $(basename ${MODULES_TAR})"
    
    # Extract module version from tarball name (e.g., modules-6.12.63-puppywang.tar.gz)
    MODULES_VER=$(basename "$MODULES_TAR" | sed -n 's/modules-\(.*\)\.tar\.gz/\1/p')
    
    # Extract to temp directory first to check structure
    MODULES_EXTRACT_DIR="${DOWNLOAD_DIR}/modules-extract"
    rm -rf "${MODULES_EXTRACT_DIR}"
    mkdir -p "${MODULES_EXTRACT_DIR}"
    tar -xzf "$MODULES_TAR" -C "${MODULES_EXTRACT_DIR}"
    
    # Debug: show what was extracted
    log_debug "Modules tarball structure:"
    ls -la "${MODULES_EXTRACT_DIR}/"
    find "${MODULES_EXTRACT_DIR}" -maxdepth 3 | head -20
    
    # Check if tarball content listing helps
    log_debug "Tarball contents (first 10 lines):"
    tar -tf "$MODULES_TAR" | head -10

    # Determine the actual modules path inside tarball
    # ophub kernel packages may have different structures:
    # 1. Direct: 6.12.63-puppywang/
    # 2. Full path: lib/modules/6.12.63-puppywang/
    if [[ -d "${MODULES_EXTRACT_DIR}/${MODULES_VER}" ]]; then
        # Structure: version directory at root
        MODULES_SRC="${MODULES_EXTRACT_DIR}/${MODULES_VER}"
        log_debug "Found modules at root: ${MODULES_SRC}"
    elif [[ -d "${MODULES_EXTRACT_DIR}/lib/modules/${MODULES_VER}" ]]; then
        # Structure: lib/modules/version
        MODULES_SRC="${MODULES_EXTRACT_DIR}/lib/modules/${MODULES_VER}"
        log_debug "Found modules in lib/modules: ${MODULES_SRC}"
    else
        # Try to find it
        MODULES_SRC=$(find "${MODULES_EXTRACT_DIR}" -type d -name "${MODULES_VER}" 2>/dev/null | head -1)
        if [[ -z "$MODULES_SRC" ]]; then
            # Use first directory found
            MODULES_SRC=$(find "${MODULES_EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        fi
        log_debug "Found modules via search: ${MODULES_SRC}"
    fi
    
    if [[ -n "$MODULES_SRC" && -d "$MODULES_SRC" ]]; then
        # If same version exists, remove it first to ensure clean install
        if [[ -n "$MODULES_VER" && -d "${LIB_PATH}/lib/modules/${MODULES_VER}" ]]; then
            log_info "Removing previous modules for ${MODULES_VER}..."
            rm -rf "${LIB_PATH}/lib/modules/${MODULES_VER}"
        fi
        
        # Install modules to correct location
        mkdir -p "${LIB_PATH}/lib/modules/"
        log_info "Installing modules to ${LIB_PATH}/lib/modules/${MODULES_VER}"
        cp -r "$MODULES_SRC" "${LIB_PATH}/lib/modules/"
        
        # Verify installation
        if [[ -d "${LIB_PATH}/lib/modules/${MODULES_VER}" ]]; then
            MODULE_COUNT=$(find "${LIB_PATH}/lib/modules/${MODULES_VER}" -name "*.ko*" 2>/dev/null | wc -l)
            log_info "Installed ${MODULE_COUNT} kernel modules"
            if [[ "$MODULE_COUNT" -eq 0 ]]; then
                log_error "ERROR: No .ko files found in installed modules!"
                log_error "Source directory content: $(ls -R $MODULES_SRC | head -10)"
                exit 1
            fi
        else
            log_error "Module installation failed!"
            exit 1
        fi
        
        # Fix build symlink - ophub packages point to build machine path
        MODULES_DIR="${LIB_PATH}/lib/modules/${MODULES_VER}"
        if [[ -L "${MODULES_DIR}/build" ]]; then
            OLD_BUILD=$(readlink "${MODULES_DIR}/build")
            if [[ "$OLD_BUILD" == /opt/* || "$OLD_BUILD" == /home/* || ! -d "$OLD_BUILD" ]]; then
                log_info "Fixing build symlink (was pointing to: ${OLD_BUILD})"
                rm -f "${MODULES_DIR}/build"
                # Point to local headers if exists, otherwise leave broken (will fix when headers installed)
                if [[ -d "${LIB_PATH}/usr/src/linux-headers-${MODULES_VER}" ]]; then
                    ln -sf "/usr/src/linux-headers-${MODULES_VER}" "${MODULES_DIR}/build"
                    log_info "Build symlink fixed -> /usr/src/linux-headers-${MODULES_VER}"
                else
                    log_warn "Headers not found, build symlink removed (install with -H or wait for auto-install)"
                fi
            fi
        fi
        
        # Regenerate modules dependency if running on target
        if [[ -z "$MOUNT_POINT" && -n "$MODULES_VER" ]]; then
            log_info "Running depmod for ${MODULES_VER}..."
            depmod -a "$MODULES_VER" 2>/dev/null || true
        fi
    else
        log_error "Could not find modules in extracted tarball!"
        log_debug "Contents of ${MODULES_EXTRACT_DIR}:"
        find "${MODULES_EXTRACT_DIR}" -type d | head -20
    fi
    
    rm -rf "${MODULES_EXTRACT_DIR}"
else
    log_warn "No modules tarball found"
    # Look for lib/modules directory
    MODULES_DIR=$(find "${DOWNLOAD_DIR}" -type d -path "*/lib/modules/*" 2>/dev/null | head -1)
    if [[ -n "$MODULES_DIR" ]]; then
        MODULES_VER=$(basename "$MODULES_DIR")
        log_info "Copying modules: ${MODULES_VER}"
        
        # Remove old modules directory if exists
        if [[ -d "${LIB_PATH}/lib/modules/${MODULES_VER}" ]]; then
            log_info "Removing previous modules for ${MODULES_VER}..."
            rm -rf "${LIB_PATH}/lib/modules/${MODULES_VER}"
        fi
        
        mkdir -p "${LIB_PATH}/lib/modules/"
        cp -r "$(dirname $MODULES_DIR)/${MODULES_VER}" "${LIB_PATH}/lib/modules/"
    fi
fi

# Install kernel headers
# Auto-detect: if headers directory exists for any version, user needs headers
# Install if: -H flag specified, OR existing headers found
HEADER_TAR=$(find "${DOWNLOAD_DIR}" -maxdepth 2 -name "header-*.tar.gz" 2>/dev/null | head -1)
EXISTING_HEADERS=$(ls -d "${LIB_PATH}/usr/src/linux-headers-"* 2>/dev/null | head -1)

# Determine if we should install headers
SHOULD_INSTALL_HEADERS=false
if [[ "$INSTALL_HEADERS" == "true" ]]; then
    SHOULD_INSTALL_HEADERS=true
    log_info "Headers installation requested via -H flag"
elif [[ -n "$EXISTING_HEADERS" && -z "$MOUNT_POINT" ]]; then
    # Running on target and headers exist - auto-update
    SHOULD_INSTALL_HEADERS=true
    log_info "Detected existing headers at ${EXISTING_HEADERS}, will auto-update"
fi

if [[ "$SHOULD_INSTALL_HEADERS" == "true" ]]; then
    if [[ -n "$HEADER_TAR" && -f "$HEADER_TAR" ]]; then
        # Determine kernel version from header filename
        HEADER_VER=$(basename "$HEADER_TAR" | sed -n 's/header-\(.*\)\.tar\.gz/\1/p')
        # Install path: /usr/src/linux-headers-<version>
        HEADERS_DIR="${LIB_PATH}/usr/src/linux-headers-${HEADER_VER}"
        
        log_info "Installing kernel headers for ${HEADER_VER}..."
        log_info "Headers path: ${HEADERS_DIR}"
        
        # Remove existing headers directory for this version
        if [[ -d "$HEADERS_DIR" ]]; then
            log_info "Removing previous headers for ${HEADER_VER}..."
            rm -rf "$HEADERS_DIR"
        fi
        
        # Create headers directory and extract
        mkdir -p "$HEADERS_DIR"
        tar -xzf "$HEADER_TAR" -C "$HEADERS_DIR"
        
        # Create symlink in modules directory if it exists
        if [[ -d "${LIB_PATH}/lib/modules/${HEADER_VER}" ]]; then
            log_info "Creating build symlink in modules directory..."
            rm -f "${LIB_PATH}/lib/modules/${HEADER_VER}/build"
            ln -sf "/usr/src/linux-headers-${HEADER_VER}" "${LIB_PATH}/lib/modules/${HEADER_VER}/build"
        fi
        
        # Verify installation
        HEADER_COUNT=$(find "$HEADERS_DIR" -name "*.h" 2>/dev/null | wc -l)
        log_info "Installed ${HEADER_COUNT} header files to ${HEADERS_DIR}"
        
        if [[ "$HEADER_COUNT" -eq 0 ]]; then
            log_warn "Warning: No .h files found in installed headers!"
        fi
        
        # Clean up old headers for different versions (optional)
        if [[ -n "$EXISTING_HEADERS" && "$EXISTING_HEADERS" != "$HEADERS_DIR" ]]; then
            log_info "Removing old headers: ${EXISTING_HEADERS}"
            rm -rf "$EXISTING_HEADERS"
        fi
    else
        log_warn "No headers tarball found in kernel package"
        log_info "Headers are not included in all kernel builds"
    fi
elif [[ -z "$MOUNT_POINT" ]]; then
    log_info "Skipping headers (no existing headers found, use -H to install)"
fi

# Update root symlinks (vmlinuz, initrd.img)
# These symlinks in / should point to the newly installed kernel
if [[ -n "$MODULES_VER" ]]; then
    KERNEL_FULL_VER="$MODULES_VER"
else
    # Try to get version from boot files
    KERNEL_FULL_VER=$(ls "${BOOT_PATH}"/vmlinuz-* 2>/dev/null | tail -1 | sed 's/.*vmlinuz-//')
fi

if [[ -n "$KERNEL_FULL_VER" ]]; then
    log_info "Updating root symlinks for kernel ${KERNEL_FULL_VER}..."
    
    # Determine root path for symlinks
    if [[ -n "$MOUNT_POINT" ]]; then
        ROOT_PATH="${LIB_PATH}"
    else
        ROOT_PATH="/"
    fi
    
    # Update vmlinuz symlink
    if [[ -f "${BOOT_PATH}/vmlinuz-${KERNEL_FULL_VER}" ]]; then
        # Backup old symlink to .old
        if [[ -L "${ROOT_PATH}/vmlinuz" ]]; then
            OLD_TARGET=$(readlink "${ROOT_PATH}/vmlinuz")
            ln -sf "$OLD_TARGET" "${ROOT_PATH}/vmlinuz.old" 2>/dev/null || true
        fi
        ln -sf "boot/vmlinuz-${KERNEL_FULL_VER}" "${ROOT_PATH}/vmlinuz"
        log_debug "Updated /vmlinuz -> boot/vmlinuz-${KERNEL_FULL_VER}"
    fi
    
    # Update initrd.img symlink
    if [[ -f "${BOOT_PATH}/initrd.img-${KERNEL_FULL_VER}" ]]; then
        if [[ -L "${ROOT_PATH}/initrd.img" ]]; then
            OLD_TARGET=$(readlink "${ROOT_PATH}/initrd.img")
            ln -sf "$OLD_TARGET" "${ROOT_PATH}/initrd.img.old" 2>/dev/null || true
        fi
        ln -sf "boot/initrd.img-${KERNEL_FULL_VER}" "${ROOT_PATH}/initrd.img"
        log_debug "Updated /initrd.img -> boot/initrd.img-${KERNEL_FULL_VER}"
    elif [[ -f "${BOOT_PATH}/uInitrd" ]]; then
        # Armbian uses uInitrd instead of initrd.img
        if [[ -L "${ROOT_PATH}/initrd.img" ]]; then
            OLD_TARGET=$(readlink "${ROOT_PATH}/initrd.img")
            ln -sf "$OLD_TARGET" "${ROOT_PATH}/initrd.img.old" 2>/dev/null || true
        fi
        ln -sf "boot/uInitrd" "${ROOT_PATH}/initrd.img"
        log_debug "Updated /initrd.img -> boot/uInitrd"
    fi
    
    # Show updated symlinks
    log_info "Root symlinks updated:"
    ls -la "${ROOT_PATH}/vmlinuz" "${ROOT_PATH}/initrd.img" 2>/dev/null | while read line; do
        log_debug "  $line"
    done
fi

# Show results
echo ""
log_info "=========================================="
log_info "Kernel update complete!"
log_info "=========================================="
echo ""
echo "Installed kernel files:"
ls -la "${BOOT_PATH}"/vmlinuz-* 2>/dev/null | tail -3 || echo "  (no vmlinuz found)"
echo ""
echo "Installed DTB files:"
ls "${BOOT_PATH}"/dtb/rockchip/*.dtb 2>/dev/null | wc -l | xargs -I {} echo "  {} DTB files"
echo ""
echo "Installed modules:"
ls -d "${LIB_PATH}"/lib/modules/*/ 2>/dev/null | tail -3 || echo "  (no modules found)"
echo ""

if [[ -n "$MOUNT_POINT" ]]; then
    log_info "TF card will be unmounted automatically."
    log_info "Remove TF card and insert into target device to boot."
else
    log_info "Run 'reboot' to boot into the new kernel."
fi

log_warn "If boot fails, restore from backup: ${BACKUP_DIR}"
