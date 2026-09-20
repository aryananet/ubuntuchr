#!/bin/bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR Installer
#
# FAIL-SAFE principle:
#   If OS, virtualization, boot mode, root disk, network, image, or any
#   safety condition is ambiguous, abort BEFORE any destructive write.
#
# IMPORTANT:
#   - This script ONLY targets the current VPS guest.
#   - It never accesses the hypervisor/host or other VMs.
#   - The final dd operation ERASES the current VPS system disk completely.
#   - CHR is installed from the official MikroTik RAW image.
#

set -Eeuo pipefail
umask 077

# ============================================================================
# Configuration
# ============================================================================

CHR_VERSION="7.23.5"
CHR_FILE="chr-${CHR_VERSION}.img.zip"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/${CHR_FILE}"
CHR_INFO_URL="https://mikrotik.com/download/chr"

SUPPORTED_UBUNTU_VERSIONS=("20.04" "22.04" "24.04" "26.04")

MIN_RAM_MB=256
RECOMMENDED_RAM_MB=1024

# ============================================================================
# Temporary working directory
# ============================================================================

WORKDIR="$(mktemp -d /tmp/aryananet-chr.XXXXXXXX)"
LOGFILE="${WORKDIR}/install.log"

# ============================================================================
# Colors
# ============================================================================

GREEN='\033[0;32m'
WHITE='\033[1;37m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Logging
# ============================================================================

log() {
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOGFILE"
}

info() {
    echo -e "${WHITE}$1${NC}"
    log "INFO" "$1"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
    log "WARN" "$1"
}

fail() {
    local reason="$1"

    echo
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}ABORTED — no destructive disk write was performed.${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "${WHITE}Reason: ${reason}${NC}"
    echo

    log "FAIL" "$reason"

    echo -e "${CYAN}Diagnostic log: ${LOGFILE}${NC}"
    exit 1
}

CHECK_ONLY=0
case "${1:-}" in
    "")
        ;;
    "--check-only")
        CHECK_ONLY=1
        ;;
    *)
        fail "Unknown argument '$1'. Supported argument: --check-only"
        ;;
esac

# ============================================================================
# Cleanup
# ============================================================================

LOOP_DEV=""
NBD_DEV=""
UEFI_MOUNT_DIR="${WORKDIR}/uefi-mount"
UEFI_BACKUP_DIR="${WORKDIR}/uefi-backup"

cleanup() {
    if [[ -d "${UEFI_MOUNT_DIR:-}" ]]; then
        umount "${UEFI_MOUNT_DIR}" 2>/dev/null || true
    fi

    if [[ -n "${NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
        NBD_DEV=""
    fi

    if [[ -n "${LOOP_DEV:-}" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    rm -f \
        "${WORKDIR}/${CHR_FILE}" \
        "${WORKDIR}/chr.img" \
        2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "Unexpected error on line ${LINENO}."' ERR

# ============================================================================
# Header
# ============================================================================

clear || true

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   AryanaNet — MikroTik CHR Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# ============================================================================
# 1. Root check
# ============================================================================

[[ "$(id -u)" -eq 0 ]] || fail "This installer must be run as root."

# ============================================================================
# 2. Operating system
# ============================================================================

info "Checking operating system..."

[[ -r /etc/os-release ]] \
    || fail "Cannot read /etc/os-release."

# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] \
    || fail "Unsupported OS: '${ID:-unknown}'. Only Ubuntu is supported."

VERSION_SUPPORTED=0

for version in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
    if [[ "${VERSION_ID:-}" == "$version" ]]; then
        VERSION_SUPPORTED=1
        break
    fi
done

[[ "$VERSION_SUPPORTED" -eq 1 ]] \
    || fail "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported versions: ${SUPPORTED_UBUNTU_VERSIONS[*]}."

ARCH="$(uname -m)"

[[ "$ARCH" == "x86_64" ]] \
    || fail "Unsupported architecture '$ARCH'. Only x86_64 is supported."

info "Ubuntu ${VERSION_ID} x86_64 — OK"

# ============================================================================
# 3. Virtualization check
# ============================================================================

command -v systemd-detect-virt >/dev/null 2>&1 \
    || fail "systemd-detect-virt is unavailable; refusing to continue."

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
CONTAINER_TYPE="$(systemd-detect-virt --container 2>/dev/null || true)"

if [[ -n "$CONTAINER_TYPE" && "$CONTAINER_TYPE" != "none" ]]; then
    fail "Container virtualization detected ('$CONTAINER_TYPE'). Containers are not supported."
fi

case "$VIRT_TYPE" in
    kvm)
        ;;
    qemu)
        ;;
    xen)
        ;;
    vmware)
        ;;
    microsoft)
        ;;
    bochs)
        ;;
    amazon)
        ;;
    none)
        fail "No virtualization detected. This looks like bare metal."
        ;;
    *)
        fail "Unsupported or unknown virtualization type: '$VIRT_TYPE'."
        ;;
esac

info "Virtualization: ${VIRT_TYPE} — OK"

# ============================================================================
# 4. Boot mode
# ============================================================================

if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    info "Boot mode: UEFI — OK"
else
    BOOT_MODE="Legacy BIOS"
    info "Boot mode: legacy BIOS — OK"
fi

# ============================================================================
# 5. Update Ubuntu and install prerequisites
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu package lists..."

apt-get update -y \
    || fail "apt-get update failed."

info "Upgrading installed Ubuntu packages..."

apt-get full-upgrade -y \
    || fail "apt-get full-upgrade failed."

info "Installing required utilities..."

apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    file \
    gzip \
    iproute2 \
    mount \
    util-linux \
    unzip \
    wget \
    dosfstools \
    gdisk \
    qemu-utils \
    kmod \
    || fail "Failed to install required packages."

# ============================================================================
# 6. Required commands
# ============================================================================

REQUIRED_COMMANDS=(
    awk
    blkid
    blockdev
    cp
    dd
    file
    find
    findmnt
    gzip
    ip
    lsblk
    modprobe
    mount
    mkfs.fat
    qemu-nbd
    readlink
    sha256sum
    sgdisk
    stat
    sync
    udevadm
    umount
    unzip
    wget
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "Required command not found: $cmd"
done

# ============================================================================
# 7. Root filesystem detection
# ============================================================================

info "Detecting root filesystem..."

ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

[[ -n "$ROOT_SOURCE" ]] \
    || fail "Could not determine the root filesystem source."

ROOT_SOURCE="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || echo "$ROOT_SOURCE")"

info "Root filesystem source: ${ROOT_SOURCE}"

# Reject filesystems which are obviously not a normal disk-backed installation.
ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

case "$ROOT_FSTYPE" in
    overlay|aufs|squashfs)
        fail "Root filesystem type '$ROOT_FSTYPE' is unsupported."
        ;;
    crypto_LUKS)
        fail "Root filesystem is directly on LUKS encryption; refusing automatic disk selection."
        ;;
esac

# ============================================================================
# 8. Resolve the actual physical/virtual disk backing /
# ============================================================================

#
# IMPORTANT:
# lsblk can return "sda" from PKNAME.
# That is NOT a valid device path.
#
# We explicitly convert:
#
#   sda   -> /dev/sda
#   vda   -> /dev/vda
#   nvme0n1 -> /dev/nvme0n1
#
# This fixes the previous /root/sda bug.
#

ROOT_TYPE="$(lsblk -ndo TYPE "$ROOT_SOURCE" 2>/dev/null || true)"

ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then

    # PKNAME example: sda, vda, nvme0n1
    DISK="/dev/${ROOT_PKNAME}"

else

    # If the root filesystem itself is already a whole disk,
    # use its real path directly.
    case "$ROOT_SOURCE" in
        /dev/*)
            DISK="$ROOT_SOURCE"
            ;;
        *)
            fail "Could not safely resolve root disk from '$ROOT_SOURCE'."
            ;;
    esac
fi

# Resolve possible symlinks.
DISK="$(readlink -f "$DISK" 2>/dev/null || echo "$DISK")"

# ============================================================================
# 9. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] \
    || fail "Resolved target '$DISK' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"

[[ "$DISK_TYPE" == "disk" ]] \
    || fail "Resolved target '$DISK' is not a whole disk (detected type: '$DISK_TYPE')."

# Do not write to removable devices.
#
# NOTE: lsblk's RM flag reflects /sys/block/<dev>/removable. On several
# KVM/QEMU virtio-blk setups this is reported as "1" for perfectly normal
# virtual system disks (this is a known virtio quirk, not an indication
# of a USB stick or SD card). Rejecting on RM alone therefore produces
# false positives on exactly the kind of VPS this installer targets.
#
# Instead: only abort if the device's actual bus path shows it is
# attached via USB. A virtio/paravirtual disk that merely reports
# removable=1 is allowed to proceed.
#
RM_FLAG="$(lsblk -ndo RM "$DISK" 2>/dev/null || echo 1)"

if [[ "$RM_FLAG" != "0" ]]; then
    DISK_NAME="$(basename "$DISK")"
    DEVICE_BUS_PATH="$(readlink -f "/sys/block/${DISK_NAME}/device" 2>/dev/null || true)"

    if [[ "$DEVICE_BUS_PATH" == *"/usb"* ]]; then
        fail "Target disk '$DISK' is attached via USB and marked removable. Refusing destructive operation."
    else
        warn "Target disk '$DISK' reports removable=1, but is not a USB device (common false positive on ${VIRT_TYPE} virtio disks). Continuing."
    fi
fi

# The disk must actually contain the root filesystem somewhere in its tree.
ROOT_RELATION=0

while read -r NODE_TYPE NODE_PATH NODE_MOUNT; do

    [[ -n "$NODE_PATH" ]] || continue

    if [[ "$NODE_MOUNT" == "/" ]]; then
        ROOT_RELATION=1
        break
    fi

done < <(
    lsblk -nrpo TYPE,PATH,MOUNTPOINT "$DISK" 2>/dev/null || true
)

[[ "$ROOT_RELATION" -eq 1 ]] \
    || fail "Safety check failed: '$DISK' does not clearly contain the filesystem mounted at '/'."

DISK_SIZE_BYTES="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"

[[ "$DISK_SIZE_BYTES" -gt 0 ]] \
    || fail "Could not determine size of target disk '$DISK'."

MIN_DISK_BYTES=$((1024 * 1024 * 1024))

[[ "$DISK_SIZE_BYTES" -ge "$MIN_DISK_BYTES" ]] \
    || fail "Target disk '$DISK' is smaller than 1 GiB."

DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))

info "Target disk: ${DISK} (${DISK_SIZE_MB} MiB) — OK"

# ============================================================================
# 10. Memory check
# ============================================================================

RAM_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"

[[ -n "$RAM_KB" ]] \
    || fail "Could not determine system RAM."

RAM_MB=$((RAM_KB / 1024))

if [[ "$RAM_MB" -lt "$MIN_RAM_MB" ]]; then
    fail "Only ${RAM_MB} MiB RAM detected. Minimum required by this installer: ${MIN_RAM_MB} MiB."
fi

if [[ "$RAM_MB" -lt "$RECOMMENDED_RAM_MB" ]]; then
    warn "Only ${RAM_MB} MiB RAM detected. 1024 MiB or more is recommended for CHR."
else
    info "RAM: ${RAM_MB} MiB — OK"
fi

# ============================================================================
# 11. Network detection
# ============================================================================

info "Detecting network configuration..."

INTERFACE="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
)"

[[ -n "$INTERFACE" ]] \
    || fail "Could not detect the primary network interface."

ADDR_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null |
    awk '{print $4; exit}'
)"

[[ -n "$ADDR_CIDR" ]] \
    || fail "Could not detect an IPv4 address on interface '$INTERFACE'."

IPV4="${ADDR_CIDR%%/*}"
PREFIX="${ADDR_CIDR##*/}"

GATEWAY="$(
    ip -4 route show default dev "$INTERFACE" 2>/dev/null |
    awk '/default/ {print $3; exit}'
)"

[[ -n "$GATEWAY" ]] \
    || fail "Could not detect the IPv4 default gateway."

# ============================================================================
# 12. IPv4 validation
# ============================================================================

ipv4_to_int() {
    local ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "$ip"

    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1

    ((a >= 0 && a <= 255)) || return 1
    ((b >= 0 && b <= 255)) || return 1
    ((c >= 0 && c <= 255)) || return 1
    ((d >= 0 && d <= 255)) || return 1

    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ipv4_to_int "$IPV4" >/dev/null \
    || fail "Detected IPv4 '$IPV4' is invalid."

ipv4_to_int "$GATEWAY" >/dev/null \
    || fail "Detected gateway '$GATEWAY' is invalid."

if ! [[ "$PREFIX" =~ ^[0-9]+$ ]]; then
    fail "Detected prefix '/$PREFIX' is invalid."
fi

if (( PREFIX < 1 || PREFIX > 32 )); then
    fail "Detected prefix '/$PREFIX' is out of range."
fi

info "Network interface: ${INTERFACE}"
info "IPv4 address: ${IPV4}/${PREFIX}"
info "Gateway: ${GATEWAY}"

warn "IPv4 is detected automatically. IPv6 configuration is not modified by this installer."

# ============================================================================
# 13. Download CHR image
# ============================================================================

echo
echo -e "${CYAN}Detected configuration:${NC}"
echo
echo -e "${WHITE}Ubuntu             : ${GREEN}${VERSION_ID}${NC}"
echo -e "${WHITE}Architecture       : ${GREEN}${ARCH}${NC}"
echo -e "${WHITE}Virtualization     : ${GREEN}${VIRT_TYPE}${NC}"
echo -e "${WHITE}Boot mode          : ${GREEN}${BOOT_MODE}${NC}"
echo -e "${WHITE}Network Interface  : ${GREEN}${INTERFACE}${NC}"
echo -e "${WHITE}IPv4               : ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "${WHITE}Gateway            : ${GREEN}${GATEWAY}${NC}"
echo -e "${WHITE}Target Disk        : ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk Size          : ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}RAM                : ${GREEN}${RAM_MB} MiB${NC}"
echo -e "${WHITE}CHR Version        : ${GREEN}${CHR_VERSION}${NC}"
echo -e "${WHITE}CHR Preparation    : ${GREEN}${BOOT_MODE}${NC}"
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo -e "${CYAN}CHECK-ONLY mode enabled.${NC}"
    echo -e "${YELLOW}The target disk will not be modified in this mode.${NC}"
    echo
else
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}                 WARNING${NC}"
    echo -e "${RED}========================================${NC}"
    echo
    echo -e "${YELLOW}THIS OPERATION WILL COMPLETELY ERASE:${NC}"
    echo -e "${YELLOW}  ${DISK}${NC}"
    echo
    echo -e "${YELLOW}The current Ubuntu operating system, files,${NC}"
    echo -e "${YELLOW}partitions and all data on that disk will be destroyed.${NC}"
    echo
    echo -e "${RED}This operation cannot be undone.${NC}"
    echo

    read -r -p "Type YES to continue: " CONFIRM

    [[ "$CONFIRM" == "YES" ]] || {
        echo -e "${YELLOW}Installation cancelled. The current system was not modified.${NC}"
        exit 0
    }
fi

# ============================================================================
# 14. Download
# ============================================================================

info "[1/4] Downloading MikroTik CHR ${CHR_VERSION}..."

cd "$WORKDIR"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    --retry-connrefused \
    --server-response \
    "$CHR_URL" \
    -O "$CHR_FILE" \
    || fail "Failed to download CHR image."

[[ -s "$CHR_FILE" ]] \
    || fail "Downloaded CHR archive is empty."

DOWNLOAD_SIZE="$(stat -c%s "$CHR_FILE" 2>/dev/null || echo 0)"

[[ "$DOWNLOAD_SIZE" -gt 0 ]] \
    || fail "Downloaded file has invalid size."

# ============================================================================
# 15. ZIP integrity check
# ============================================================================

info "[2/4] Verifying downloaded archive..."

FILE_TYPE="$(file -b "$CHR_FILE" 2>/dev/null || true)"

case "$FILE_TYPE" in
    Zip\ archive*)
        ;;
    *)
        fail "Downloaded file is not a valid ZIP archive. Detected type: '$FILE_TYPE'."
        ;;
esac

unzip -t "$CHR_FILE" >/dev/null \
    || fail "ZIP integrity test failed."

ACTUAL_SHA256="$(sha256sum "$CHR_FILE" | awk '{print $1}')"

echo
echo -e "${CYAN}Downloaded file:${NC} ${CHR_FILE}"
echo -e "${CYAN}Size:${NC} ${DOWNLOAD_SIZE} bytes"
echo -e "${CYAN}SHA256:${NC} ${ACTUAL_SHA256}"
echo

echo -e "${YELLOW}For maximum security, compare the SHA256 above with the${NC}"
echo -e "${YELLOW}checksum shown on MikroTik's official CHR download page:${NC}"
echo
echo -e "${CYAN}${CHR_INFO_URL}${NC}"
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo -e "${CYAN}CHECK-ONLY mode: checksum is shown above; continuing without disk write.${NC}"
    echo
else
    read -r -p "Type YES after verifying the checksum: " CONFIRM2

    [[ "$CONFIRM2" == "YES" ]] || {
        echo -e "${YELLOW}Installation cancelled. No disk write was performed.${NC}"
        exit 0
    }
fi

# ============================================================================
# 16. Extract RAW image
# ============================================================================

info "[3/4] Extracting CHR RAW image..."

#
# The downloaded archive is a ZIP file. Extract the single .img member and
# validate it before doing anything destructive.
#

IMAGE="${WORKDIR}/chr.img"
IMAGE_MEMBER="$({ unzip -Z1 "$CHR_FILE" 2>/dev/null || true; } | grep -i '\.img$' | head -n1)"

[[ -n "$IMAGE_MEMBER" ]] \
    || fail "Could not find a .img file inside the downloaded ZIP archive."

unzip -p "$CHR_FILE" "$IMAGE_MEMBER" > "$IMAGE" \
    || fail "Failed to extract CHR RAW image from ZIP archive."

[[ -s "$IMAGE" ]] \
    || fail "Extracted CHR image is empty."

IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE" 2>/dev/null || echo 0)"

[[ "$IMAGE_SIZE_BYTES" -gt $((50 * 1024 * 1024)) ]] \
    || fail "Extracted CHR image is suspiciously small."

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))

info "CHR RAW image size: ${IMAGE_SIZE_MB} MiB"

# ============================================================================
# 16a. UEFI preparation
# ============================================================================

if [[ "$BOOT_MODE" == "UEFI" ]]; then

    # Standard x86 CHR RAW images use a non-FAT boot partition. UEFI firmware
    # expects the EFI System Partition to contain a FAT filesystem. We prepare
    # a COPY of the downloaded CHR image only; the real target disk is never
    # touched during this conversion.
    #
    # This follows the same general conversion used by the fat-chr project:
    # preserve the RouterOS boot files, recreate partition 1 as FAT, restore
    # the boot files, and ensure partition 1 is marked as an EFI System
    # Partition in GPT.

    info "Preparing CHR image for UEFI boot..."

    mkdir -p "$UEFI_MOUNT_DIR" "$UEFI_BACKUP_DIR"

    modprobe nbd max_part=8 \
        || fail "Could not load the Linux nbd module required for UEFI image preparation."

    for candidate in /dev/nbd*; do
        [[ -b "$candidate" ]] || continue
        candidate_size="$(blockdev --getsize64 "$candidate" 2>/dev/null || echo 0)"
        if [[ "$candidate_size" == "0" ]]; then
            NBD_DEV="$candidate"
            break
        fi
    done

    [[ -n "$NBD_DEV" ]] \
        || fail "Could not find a free NBD device for UEFI image preparation."

    qemu-nbd --connect="$NBD_DEV" --format=raw "$IMAGE" \
        || fail "Failed to attach CHR image to NBD device '${NBD_DEV}'."

    udevadm settle 2>/dev/null || true
    sleep 1

    EFI_PART="${NBD_DEV}p1"
    ROOT_PART="${NBD_DEV}p2"

    [[ -b "$EFI_PART" ]] \
        || fail "UEFI preparation failed: boot partition '${EFI_PART}' was not detected."

    [[ -b "$ROOT_PART" ]] \
        || fail "UEFI preparation failed: RouterOS root partition '${ROOT_PART}' was not detected."

    EFI_FSTYPE="$(blkid -o value -s TYPE "$EFI_PART" 2>/dev/null || true)"
    info "Original CHR boot partition filesystem: ${EFI_FSTYPE:-unknown}"

    mount -o ro "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the original CHR boot partition."

    BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f \
        \( -iname 'bootx64.efi' -o -iname 'grubx64.efi' -o -iname 'bootia32.efi' \) \
        -print -quit 2>/dev/null || true)"

    [[ -n "$BOOT_FILE" ]] \
        || fail "The CHR boot partition does not contain a detectable EFI bootloader."

    cp -R "$UEFI_MOUNT_DIR/." "$UEFI_BACKUP_DIR/" \
        || fail "Failed to preserve the original CHR boot files before FAT conversion."

    umount "$UEFI_MOUNT_DIR" \
        || fail "Failed to unmount the original CHR boot partition."

    info "Converting CHR boot partition to FAT16 for UEFI..."

    mkfs.fat -F 16 "$EFI_PART" >/dev/null \
        || fail "Failed to create FAT16 filesystem on the CHR boot partition."

    mount "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the new FAT16 boot partition."

    cp -R "$UEFI_BACKUP_DIR/." "$UEFI_MOUNT_DIR/" \
        || fail "Failed to restore CHR EFI boot files to the FAT16 partition."

    sync

    RESTORED_BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f -iname 'bootx64.efi' -print -quit 2>/dev/null || true)"

    [[ -n "$RESTORED_BOOT_FILE" ]] \
        || fail "UEFI bootloader verification failed after FAT conversion."

    umount "$UEFI_MOUNT_DIR" \
        || fail "Failed to unmount the prepared UEFI boot partition."

    sync
    qemu-nbd --disconnect "$NBD_DEV" >/dev/null \
        || fail "Failed to disconnect the prepared CHR image from NBD."
    NBD_DEV=""

    # Verify that a valid GPT exists and make absolutely sure partition 1 is
    # typed as an EFI System Partition. We intentionally do not rebuild the
    # whole partition table here; only the image file is modified.
    GPT_INFO="$(sgdisk -i 1 "$IMAGE" 2>&1 || true)"

    grep -qi 'Partition GUID code:[[:space:]]*EF00' <<< "$GPT_INFO" || {
        info "Marking CHR partition 1 as an EFI System Partition..."
        sgdisk -t 1:EF00 -c 1:'RouterOS Boot' "$IMAGE" >/dev/null \
            || fail "Could not mark CHR partition 1 as an EFI System Partition."
    }

    GPT_INFO_FINAL="$(sgdisk -i 1 "$IMAGE" 2>&1 || true)"

    grep -qi 'Partition GUID code:[[:space:]]*EF00' <<< "$GPT_INFO_FINAL" \
        || fail "UEFI image verification failed: partition 1 is not marked as EFI System Partition."

    info "UEFI-compatible CHR image preparation — OK"

else
    info "Legacy BIOS detected — using the official CHR RAW image unchanged."
fi

# ============================================================================
# 16b. Final image-vs-disk size check
# ============================================================================

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB). Refusing to overwrite disk."
fi

info "CHR image fits inside target disk — OK"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}          CHECK-ONLY COMPLETED${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${WHITE}Boot mode     :${NC} ${GREEN}${BOOT_MODE}${NC}"
    echo -e "${WHITE}CHR image     :${NC} ${GREEN}${IMAGE_SIZE_MB} MiB${NC}"
    echo -e "${WHITE}Target disk   :${NC} ${GREEN}${DISK}${NC}"
    echo
    echo -e "${YELLOW}No destructive disk write was performed.${NC}"
    echo -e "${YELLOW}The target disk ${DISK} was not modified.${NC}"
    echo -e "${YELLOW}The VPS remains on Ubuntu.${NC}"
    echo
    exit 0
fi

# ============================================================================
# 17. Critical image-vs-disk safety check
# ============================================================================

# ============================================================================
# 18. Final pre-write verification
# ============================================================================

echo
echo -e "${RED}========================================${NC}"
echo -e "${RED}          FINAL DESTRUCTIVE STEP${NC}"
echo -e "${RED}========================================${NC}"
echo
echo -e "${WHITE}Target disk:${NC} ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk size  :${NC} ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}CHR image  :${NC} ${GREEN}${IMAGE_SIZE_MB} MiB (${BOOT_MODE})${NC}"
echo -e "${WHITE}Network    :${NC} ${GREEN}${IPV4}/${PREFIX} via ${GATEWAY}${NC}"
echo
echo -e "${RED}The next command will overwrite ${DISK}.${NC}"
echo -e "${RED}Ubuntu will be destroyed permanently.${NC}"
echo

read -r -p "Type INSTALL to start writing CHR: " FINAL_CONFIRM

[[ "$FINAL_CONFIRM" == "INSTALL" ]] || {
    echo -e "${YELLOW}Installation cancelled. No destructive write was performed.${NC}"
    exit 0
}

# ============================================================================
# 19. Re-check target immediately before dd
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] \
    || fail "Target disk '$DISK' disappeared."

FINAL_DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"

[[ "$FINAL_DISK_TYPE" == "disk" ]] \
    || fail "Target '$DISK' is no longer detected as a whole disk."

FINAL_DISK_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"

[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] \
    || fail "Target disk size changed unexpectedly. Refusing to write."

# ============================================================================
# 20. Destructive CHR installation
# ============================================================================

info "[4/4] Writing MikroTik CHR image to ${DISK}..."
echo
echo -e "${RED}DO NOT INTERRUPT THE WRITE PROCESS.${NC}"
echo

sync

dd \
    if="$IMAGE" \
    of="$DISK" \
    bs=4M \
    iflag=fullblock \
    status=progress \
    conv=fsync

sync

# ============================================================================
# 21. Finished
# ============================================================================

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MikroTik CHR Installed${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${WHITE}CHR Version : ${CYAN}${CHR_VERSION}${NC}"
echo -e "${WHITE}Disk        : ${CYAN}${DISK}${NC}"
echo
echo -e "${YELLOW}The Ubuntu operating system has been replaced by MikroTik CHR.${NC}"
echo
echo -e "${CYAN}Next steps:${NC}"
echo
echo -e "${WHITE}1.${NC} Open the VPS VNC/Console from your hosting panel."
echo
echo -e "${WHITE}2.${NC} Boot MikroTik CHR."
echo
echo -e "${WHITE}3.${NC} The default MikroTik login is:${NC}"
echo -e "   ${CYAN}Username: admin${NC}"
echo -e "   ${CYAN}Password: empty / no password${NC}"
echo
echo -e "${WHITE}4.${NC} Configure the network manually from the CHR console."
echo
echo -e "${YELLOW}IMPORTANT: Set a strong unique administrator password immediately.${NC}"
echo
echo -e "${YELLOW}Do NOT use a shared password such as aryananetX# on production systems.${NC}"
echo
echo -e "${YELLOW}IPv6 is not configured automatically by this installer.${NC}"
echo
echo -e "${YELLOW}The free CHR license has a 1 Mbps per-interface limitation until licensed.${NC}"
echo
echo -e "${GREEN}Installation completed successfully.${NC}"
echo

read -r -p "Press ENTER to reboot the VPS..." _

sync
sleep 2
reboot
