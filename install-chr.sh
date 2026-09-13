#!/bin/bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR Installer
#
# FAIL-SAFE principle:
#   If OS, virtualization, boot mode, root disk, network, image,
#   or any safety condition is ambiguous, abort before destructive write.
#
# IMPORTANT:
#   - This script is intended for Ubuntu VPS guests.
#   - The final dd operation completely erases the current system disk.
#   - No host/hypervisor/other VM is accessed.
#   - Always keep a backup before running this installer.
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

SUPPORTED_UBUNTU_VERSIONS=(
    "20.04"
    "22.04"
    "24.04"
    "26.04"
)

MIN_RAM_MB=256
RECOMMENDED_RAM_MB=1024

# ============================================================================
# Temporary workspace
# ============================================================================

WORKDIR="$(mktemp -d /tmp/aryananet-chr.XXXXXXXX)"
LOGFILE="${WORKDIR}/install.log"

LOOP_DEV=""

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
    printf '%s [%s] %s\n' \
        "$(date '+%F %T')" \
        "$1" \
        "$2" >> "$LOGFILE"
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

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
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

clear 2>/dev/null || true

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   AryanaNet — MikroTik CHR Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# ============================================================================
# 1. Root check
# ============================================================================

[[ "$(id -u)" -eq 0 ]] || fail "This installer must be run as root."

# ============================================================================
# 2. Operating system check
# ============================================================================

info "Checking operating system..."

[[ -r /etc/os-release ]] \
    || fail "Cannot read /etc/os-release."

# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] \
    || fail "Unsupported operating system '${ID:-unknown}'. Only Ubuntu is supported."

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

info "Ubuntu ${VERSION_ID} / x86_64 — OK"

# ============================================================================
# 3. Virtualization check
# ============================================================================

command -v systemd-detect-virt >/dev/null 2>&1 \
    || fail "systemd-detect-virt is unavailable."

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
CONTAINER_TYPE="$(systemd-detect-virt --container 2>/dev/null || true)"

if [[ -n "$CONTAINER_TYPE" && "$CONTAINER_TYPE" != "none" ]]; then
    fail "Container virtualization detected: '${CONTAINER_TYPE}'. Containers are not supported."
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
    oracle)
        ;;
    bochs)
        ;;
    amazon)
        ;;
    none)
        fail "No virtualization detected. This appears to be bare metal."
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
    fail "This VPS is currently booted in UEFI mode. Refusing installation because this installer uses the CHR RAW image in legacy BIOS mode."
fi

info "Boot mode: legacy BIOS — OK"

# ============================================================================
# 5. Update Ubuntu
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu package lists..."

apt-get update -y \
    || fail "apt-get update failed."

info "Upgrading installed Ubuntu packages..."

apt-get full-upgrade -y \
    || fail "apt-get full-upgrade failed."

# ============================================================================
# 6. Install required utilities
# ============================================================================

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
    || fail "Failed to install required packages."

# ============================================================================
# 7. Required commands
# ============================================================================

REQUIRED_COMMANDS=(
    awk
    blockdev
    dd
    file
    findmnt
    gzip
    ip
    lsblk
    mount
    readlink
    sha256sum
    stat
    sync
    umount
    unzip
    wget
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "Required command not found: ${cmd}"
done

# ============================================================================
# 8. Detect root filesystem
# ============================================================================

info "Detecting root filesystem..."

ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

[[ -n "$ROOT_SOURCE" ]] \
    || fail "Could not determine the root filesystem."

ROOT_SOURCE_REAL="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || echo "$ROOT_SOURCE")"

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

case "$ROOT_FSTYPE" in
    overlay|aufs|squashfs)
        fail "Unsupported root filesystem type: '${ROOT_FSTYPE}'."
        ;;
esac

info "Root filesystem: ${ROOT_SOURCE_REAL}"

# ============================================================================
# 9. Detect the system disk
# ============================================================================

#
# Normal VPS examples:
#
#   /dev/sda1   -> /dev/sda
#   /dev/vda1   -> /dev/vda
#   /dev/nvme0n1p1 -> /dev/nvme0n1
#
# We use PKNAME and explicitly add /dev/ so that:
#
#   sda -> /dev/sda
#
# instead of accidentally producing:
#
#   /root/sda
#

ROOT_TYPE="$(lsblk -ndo TYPE "$ROOT_SOURCE_REAL" 2>/dev/null || true)"
ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE_REAL" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then

    DISK="/dev/${ROOT_PKNAME}"

else

    if [[ "$ROOT_TYPE" == "disk" && "$ROOT_SOURCE_REAL" == /dev/* ]]; then
        DISK="$ROOT_SOURCE_REAL"
    else
        fail "Could not safely determine the system disk from root filesystem '${ROOT_SOURCE_REAL}'."
    fi

fi

DISK="$(readlink -f "$DISK" 2>/dev/null || echo "$DISK")"

# ============================================================================
# 10. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] \
    || fail "Resolved target '${DISK}' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"

[[ "$DISK_TYPE" == "disk" ]] \
    || fail "Resolved target '${DISK}' is not a whole disk. Detected type: '${DISK_TYPE}'."

# ---------------------------------------------------------------------------
# Check removable flag
# ---------------------------------------------------------------------------

RM_FLAG="$(lsblk -ndo RM "$DISK" 2>/dev/null || echo 1)"

[[ "$RM_FLAG" == "0" ]] \
    || fail "Target disk '${DISK}' is marked as removable. Refusing to overwrite it."

# ---------------------------------------------------------------------------
# Check that root filesystem is actually somewhere on this disk
# ---------------------------------------------------------------------------

ROOT_FOUND=0

while read -r NODE_PATH NODE_TYPE NODE_MOUNT; do

    [[ -n "$NODE_PATH" ]] || continue

    if [[ "$NODE_MOUNT" == "/" ]]; then
        ROOT_FOUND=1
        break
    fi

done < <(
    lsblk -nrpo NAME,TYPE,MOUNTPOINT "$DISK" 2>/dev/null || true
)

(( ROOT_FOUND == 1 )) \
    || fail "Safety check failed: '${DISK}' does not clearly contain the root filesystem '${ROOT_SOURCE_REAL}'."

# ---------------------------------------------------------------------------
# Reject complicated storage layouts
# ---------------------------------------------------------------------------

case "$ROOT_TYPE" in
    lvm)
        fail "Root filesystem is on LVM. Automatic conversion is disabled for safety."
        ;;
    crypt)
        fail "Root filesystem is on an encrypted/crypt device. Automatic conversion is disabled for safety."
        ;;
    raid*)
        fail "Root filesystem is on software RAID. Automatic conversion is disabled for safety."
        ;;
esac

# ---------------------------------------------------------------------------
# Get disk size
# ---------------------------------------------------------------------------

DISK_SIZE_BYTES="$(
    blockdev --getsize64 "$DISK" 2>/dev/null || echo 0
)"

[[ "$DISK_SIZE_BYTES" -gt 0 ]] \
    || fail "Could not determine the size of target disk '${DISK}'."

MIN_DISK_BYTES=$((1024 * 1024 * 1024))

[[ "$DISK_SIZE_BYTES" -ge "$MIN_DISK_BYTES" ]] \
    || fail "Target disk '${DISK}' is smaller than 1 GiB."

DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))

info "Target disk: ${DISK} (${DISK_SIZE_MB} MiB) — OK"

# ============================================================================
# 11. RAM check
# ============================================================================

RAM_KB="$(
    awk '/MemTotal:/ {print $2; exit}' /proc/meminfo
)"

[[ -n "$RAM_KB" ]] \
    || fail "Could not determine available RAM."

RAM_MB=$((RAM_KB / 1024))

if (( RAM_MB < MIN_RAM_MB )); then
    fail "Only ${RAM_MB} MiB RAM detected. Minimum allowed by this installer: ${MIN_RAM_MB} MiB."
fi

if (( RAM_MB < RECOMMENDED_RAM_MB )); then
    warn "RAM is ${RAM_MB} MiB. ${RECOMMENDED_RAM_MB} MiB or more is recommended for CHR."
else
    info "RAM: ${RAM_MB} MiB — OK"
fi

# ============================================================================
# 12. Network detection
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
    || fail "Could not detect the primary IPv4 network interface."

ADDR_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null |
    awk '{print $4; exit}'
)"

[[ -n "$ADDR_CIDR" ]] \
    || fail "Could not detect an IPv4 address on interface '${INTERFACE}'."

IPV4="${ADDR_CIDR%%/*}"
PREFIX="${ADDR_CIDR##*/}"

GATEWAY="$(
    ip -4 route show default dev "$INTERFACE" 2>/dev/null |
    awk '/default/ {print $3; exit}'
)"

[[ -n "$GATEWAY" ]] \
    || fail "Could not detect the IPv4 default gateway."

# ============================================================================
# 13. IPv4 validation
# ============================================================================

validate_ipv4() {
    local ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "$ip"

    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] \
        || return 1

    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    [[ "$d" =~ ^[0-9]+$ ]] || return 1

    (( a >= 0 && a <= 255 )) || return 1
    (( b >= 0 && b <= 255 )) || return 1
    (( c >= 0 && c <= 255 )) || return 1
    (( d >= 0 && d <= 255 )) || return 1

    return 0
}

validate_ipv4 "$IPV4" \
    || fail "Detected IPv4 address '${IPV4}' is invalid."

validate_ipv4 "$GATEWAY" \
    || fail "Detected gateway '${GATEWAY}' is invalid."

[[ "$PREFIX" =~ ^[0-9]+$ ]] \
    || fail "Detected prefix '/${PREFIX}' is invalid."

(( PREFIX >= 1 && PREFIX <= 32 )) \
    || fail "Detected prefix '/${PREFIX}' is out of range."

info "Network interface: ${INTERFACE}"
info "IPv4 address: ${IPV4}/${PREFIX}"
info "Gateway: ${GATEWAY}"

warn "IPv4 is detected only for information. This installer does not inject network configuration into CHR."
warn "IPv6 configuration is not modified."

# ============================================================================
# 14. Show detected configuration
# ============================================================================

echo
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}         DETECTED CONFIGURATION         ${NC}"
echo -e "${CYAN}========================================${NC}"
echo

echo -e "${WHITE}Ubuntu             : ${GREEN}${VERSION_ID}${NC}"
echo -e "${WHITE}Architecture       : ${GREEN}${ARCH}${NC}"
echo -e "${WHITE}Virtualization     : ${GREEN}${VIRT_TYPE}${NC}"
echo -e "${WHITE}Boot Mode          : ${GREEN}Legacy BIOS${NC}"
echo -e "${WHITE}Network Interface  : ${GREEN}${INTERFACE}${NC}"
echo -e "${WHITE}IPv4               : ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "${WHITE}Gateway            : ${GREEN}${GATEWAY}${NC}"
echo -e "${WHITE}Target Disk        : ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk Size          : ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}RAM                : ${GREEN}${RAM_MB} MiB${NC}"
echo -e "${WHITE}CHR Version        : ${GREEN}${CHR_VERSION}${NC}"
echo

# ============================================================================
# 15. First destructive confirmation
# ============================================================================

echo -e "${RED}========================================${NC}"
echo -e "${RED}                 WARNING                ${NC}"
echo -e "${RED}========================================${NC}"
echo

echo -e "${YELLOW}This operation will permanently erase:${NC}"
echo -e "${RED}    ${DISK}${NC}"
echo

echo -e "${YELLOW}The current Ubuntu operating system, files, partitions${NC}"
echo -e "${YELLOW}and all other data stored on this disk will be destroyed.${NC}"
echo

echo -e "${RED}THIS CANNOT BE UNDONE.${NC}"
echo

read -r -p "Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
fi

# ============================================================================
# 16. Download CHR
# ============================================================================

info "[1/5] Downloading MikroTik CHR ${CHR_VERSION}..."

cd "$WORKDIR"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    --retry-connrefused \
    "$CHR_URL" \
    -O "$CHR_FILE" \
    || fail "CHR download failed."

[[ -s "$CHR_FILE" ]] \
    || fail "Downloaded CHR archive is empty."

DOWNLOAD_SIZE="$(
    stat -c%s "$CHR_FILE" 2>/dev/null || echo 0
)"

[[ "$DOWNLOAD_SIZE" -gt 0 ]] \
    || fail "Downloaded CHR archive has an invalid size."

# ============================================================================
# 17. Verify ZIP
# ============================================================================

info "[2/5] Verifying downloaded archive..."

FILE_TYPE="$(
    file -b "$CHR_FILE" 2>/dev/null || true
)"

case "$FILE_TYPE" in
    Zip\ archive*)
        ;;
    *)
        fail "Downloaded file is not a valid ZIP archive. Detected type: '${FILE_TYPE}'."
        ;;
esac

unzip -t "$CHR_FILE" >/dev/null \
    || fail "ZIP integrity test failed."

ACTUAL_SHA256="$(
    sha256sum "$CHR_FILE" | awk '{print $1}'
)"

echo
echo -e "${CYAN}Downloaded file:${NC} ${CHR_FILE}"
echo -e "${CYAN}Size:${NC} ${DOWNLOAD_SIZE} bytes"
echo -e "${CYAN}SHA256:${NC} ${ACTUAL_SHA256}"
echo

echo -e "${YELLOW}Compare this SHA256 with the checksum displayed on the official MikroTik CHR page:${NC}"
echo -e "${CYAN}${CHR_INFO_URL}${NC}"
echo

read -r -p "After checking the checksum, type YES to continue: " CONFIRM2

if [[ "$CONFIRM2" != "YES" ]]; then
    echo
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
fi

# ============================================================================
# 18. Extract RAW image from ZIP
# ============================================================================

info "[3/5] Extracting CHR RAW image..."

ZIP_IMAGE_ENTRY="$(
    unzip -Z1 "$CHR_FILE" 2>/dev/null |
    awk '$0 ~ /\.img$/ {print; exit}'
)"

[[ -n "$ZIP_IMAGE_ENTRY" ]] \
    || fail "Could not find a .img file inside the downloaded CHR archive."

info "Image inside archive: ${ZIP_IMAGE_ENTRY}"

unzip -p "$CHR_FILE" "$ZIP_IMAGE_ENTRY" > "${WORKDIR}/chr.img" \
    || fail "Failed to extract CHR RAW image."

IMAGE="${WORKDIR}/chr.img"

[[ -s "$IMAGE" ]] \
    || fail "Extracted CHR RAW image is empty."

IMAGE_SIZE_BYTES="$(
    stat -c%s "$IMAGE" 2>/dev/null || echo 0
)"

[[ "$IMAGE_SIZE_BYTES" -gt $((50 * 1024 * 1024)) ]] \
    || fail "Extracted CHR image is suspiciously small."

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))

info "CHR RAW image size: ${IMAGE_SIZE_MB} MiB"

# ============================================================================
# 19. Image must fit inside target disk
# ============================================================================

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB)."
fi

info "CHR image fits inside target disk — OK"

# ============================================================================
# 20. Final warning
# ============================================================================

echo
echo -e "${RED}========================================${NC}"
echo -e "${RED}          FINAL DESTRUCTIVE STEP       ${NC}"
echo -e "${RED}========================================${NC}"
echo

echo -e "${WHITE}Target disk : ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk size   : ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}CHR image   : ${GREEN}${IMAGE_SIZE_MB} MiB${NC}"
echo -e "${WHITE}Interface   : ${GREEN}${INTERFACE}${NC}"
echo -e "${WHITE}IPv4        : ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "${WHITE}Gateway     : ${GREEN}${GATEWAY}${NC}"
echo

echo -e "${YELLOW}The next step will overwrite the target disk completely.${NC}"
echo -e "${RED}${DISK}${NC}"
echo
echo -e "${RED}Ubuntu and all existing data on this disk will be destroyed.${NC}"
echo

read -r -p "Type INSTALL to start writing MikroTik CHR: " FINAL_CONFIRM

if [[ "$FINAL_CONFIRM" != "INSTALL" ]]; then
    echo
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
fi

# ============================================================================
# 21. Final disk re-check immediately before dd
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] \
    || fail "Target disk '${DISK}' is no longer available."

FINAL_DISK_TYPE="$(
    lsblk -ndo TYPE "$DISK" 2>/dev/null || true
)"

[[ "$FINAL_DISK_TYPE" == "disk" ]] \
    || fail "Target '${DISK}' is no longer detected as a whole disk."

FINAL_DISK_SIZE="$(
    blockdev --getsize64 "$DISK" 2>/dev/null || echo 0
)"

[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] \
    || fail "Target disk size changed unexpectedly. Refusing destructive write."

FINAL_ROOT_FOUND=0

while read -r NODE_PATH NODE_TYPE NODE_MOUNT; do

    [[ -n "$NODE_PATH" ]] || continue

    if [[ "$NODE_MOUNT" == "/" ]]; then
        FINAL_ROOT_FOUND=1
        break
    fi

done < <(
    lsblk -nrpo NAME,TYPE,MOUNTPOINT "$DISK" 2>/dev/null || true
)

(( FINAL_ROOT_FOUND == 1 )) \
    || fail "Final safety check failed: '${DISK}' is no longer confirmed as the disk containing '/'."

info "Final disk checks passed."

# ============================================================================
# 22. Destructive installation
# ============================================================================

info "[4/5] Writing MikroTik CHR to ${DISK}..."
echo
echo -e "${RED}DO NOT INTERRUPT THIS PROCESS.${NC}"
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
# 23. Cleanup
# ============================================================================

info "[5/5] Cleaning temporary files..."

rm -f \
    "${WORKDIR}/${CHR_FILE}" \
    "${WORKDIR}/chr.img"

# ============================================================================
# 24. Completion
# ============================================================================

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MikroTik CHR Installed           ${NC}"
echo -e "${GREEN}========================================${NC}"
echo

echo -e "${WHITE}CHR Version : ${CYAN}${CHR_VERSION}${NC}"
echo -e "${WHITE}Target Disk : ${CYAN}${DISK}${NC}"
echo

echo -e "${YELLOW}Ubuntu has been replaced by MikroTik CHR.${NC}"
echo

echo -e "${CYAN}Next steps:${NC}"
echo

echo -e "${WHITE}1.${NC} Open the VPS VNC / Console from your hosting provider."
echo
echo -e "${WHITE}2.${NC} Boot MikroTik CHR."
echo
echo -e "${WHITE}3.${NC} The default MikroTik login is:"
echo -e "   ${CYAN}Username: admin${NC}"
echo -e "   ${CYAN}Password: empty / no password${NC}"
echo
echo -e "${WHITE}4.${NC} Configure the CHR network from the console if required."
echo
echo -e "${WHITE}5.${NC} Set a strong unique administrator password immediately."
echo

echo -e "${YELLOW}IMPORTANT:${NC}"
echo -e "${YELLOW}This installer does NOT create a shared/default CHR administrator password.${NC}"
echo

echo -e "${YELLOW}Detected network information before installation:${NC}"
echo -e "${CYAN}Interface : ${INTERFACE}${NC}"
echo -e "${CYAN}IPv4      : ${IPV4}/${PREFIX}${NC}"
echo -e "${CYAN}Gateway   : ${GATEWAY}${NC}"
echo

echo -e "${YELLOW}IPv6 is not configured by this installer.${NC}"
echo
echo -e "${YELLOW}Free CHR licensing has throughput limitations until the required license is applied.${NC}"
echo

read -r -p "Press ENTER to reboot the VPS..." _

sync
sleep 2

reboot
