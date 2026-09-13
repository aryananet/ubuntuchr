#!/bin/bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR Installer
#
# IMPORTANT:
#   This script is DESTRUCTIVE. The final dd operation permanently erases
#   the current VPS system disk and replaces Ubuntu with MikroTik CHR.
#
# FAIL-SAFE POLICY:
#   If the OS, virtualization, boot mode, root disk, network, image, or any
#   other safety-critical condition is ambiguous, the script aborts before dd.
#
# This script is designed for standard full-virtualization Ubuntu VPS guests.
# It does not access the hypervisor host or any other VM.
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
MIN_DISK_BYTES=$((1024 * 1024 * 1024))
MIN_IMAGE_BYTES=$((50 * 1024 * 1024))

# ============================================================================
# Working directory / logging
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
# Logging / errors
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
    echo -e "${CYAN}Diagnostic log: ${LOGFILE}${NC}"

    log "FAIL" "$reason"
    exit 1
}

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
# 1. Root
# ============================================================================

[[ "$(id -u)" -eq 0 ]] || fail "This installer must be run as root."

# ============================================================================
# 2. Ubuntu / architecture
# ============================================================================

[[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || fail "Unsupported operating system '${ID:-unknown}'. Only Ubuntu is supported."

VERSION_SUPPORTED=0
for version in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
    if [[ "${VERSION_ID:-}" == "$version" ]]; then
        VERSION_SUPPORTED=1
        break
    fi
done

[[ "$VERSION_SUPPORTED" -eq 1 ]] || fail "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported: ${SUPPORTED_UBUNTU_VERSIONS[*]}."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || fail "Unsupported architecture '$ARCH'. Only x86_64 is supported."

info "Ubuntu ${VERSION_ID} / x86_64 — OK"

# ============================================================================
# 3. Virtualization
# ============================================================================

command -v systemd-detect-virt >/dev/null 2>&1 || fail "systemd-detect-virt is unavailable."

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
CONTAINER_TYPE="$(systemd-detect-virt --container 2>/dev/null || true)"

if [[ -n "$CONTAINER_TYPE" && "$CONTAINER_TYPE" != "none" ]]; then
    fail "Container virtualization detected ('$CONTAINER_TYPE'). Containers are not supported."
fi

case "$VIRT_TYPE" in
    kvm|qemu|xen|vmware|microsoft|oracle|bochs|amazon)
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
    fail "This VPS is booted in UEFI mode. This installer requires legacy BIOS mode for the selected CHR RAW image."
fi

info "Boot mode: legacy BIOS — OK"

# ============================================================================
# 5. Update Ubuntu and install prerequisites
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu package lists..."
apt-get update -y || fail "apt-get update failed."

info "Upgrading installed Ubuntu packages..."
apt-get full-upgrade -y || fail "apt-get full-upgrade failed."

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
# 6. Required commands
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
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

# ============================================================================
# 7. Root filesystem
# ============================================================================

info "Detecting root filesystem..."

ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SOURCE" ]] || fail "Could not determine the root filesystem source."

ROOT_SOURCE_REAL="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || echo "$ROOT_SOURCE")"
ROOT_TYPE="$(lsblk -ndo TYPE "$ROOT_SOURCE_REAL" 2>/dev/null || true)"

case "$ROOT_TYPE" in
    lvm|crypt|raid*|md)
        fail "Root filesystem uses unsupported storage type '$ROOT_TYPE'."
        ;;
esac

case "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" in
    overlay|aufs|squashfs)
        fail "Unsupported root filesystem type."
        ;;
esac

info "Root filesystem: ${ROOT_SOURCE_REAL}"

# ============================================================================
# 8. Determine the exact whole disk backing /
# ============================================================================

# For a normal VPS:
#   /dev/sda1       -> PKNAME=sda       -> /dev/sda
#   /dev/vda1       -> PKNAME=vda       -> /dev/vda
#   /dev/nvme0n1p1  -> PKNAME=nvme0n1   -> /dev/nvme0n1
#
# We intentionally construct the device path from /dev/ + PKNAME so that
# 'sda' never becomes '/root/sda'.

ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE_REAL" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then
    DISK="/dev/${ROOT_PKNAME}"
elif [[ "$ROOT_TYPE" == "disk" && "$ROOT_SOURCE_REAL" == /dev/* ]]; then
    DISK="$ROOT_SOURCE_REAL"
else
    fail "Could not safely determine the whole disk backing '${ROOT_SOURCE_REAL}'."
fi

DISK="$(readlink -f "$DISK" 2>/dev/null || echo "$DISK")"

# ============================================================================
# 9. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] || fail "Resolved target '${DISK}' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] || fail "Resolved target '${DISK}' is not a whole disk (type: '${DISK_TYPE}')."

RM_FLAG="$(lsblk -ndo RM "$DISK" 2>/dev/null || echo 1)"
[[ "$RM_FLAG" == "0" ]] || fail "Target disk '${DISK}' is marked removable."

# The root filesystem must belong directly to this disk according to PKNAME.
if [[ "$ROOT_TYPE" == "disk" ]]; then
    [[ "$ROOT_SOURCE_REAL" == "$DISK" ]] || fail "Safety check failed: root disk '${ROOT_SOURCE_REAL}' does not match target '${DISK}'."
else
    ROOT_PARENT="$(lsblk -ndo PKNAME "$ROOT_SOURCE_REAL" 2>/dev/null | head -n1 || true)"
    [[ -n "$ROOT_PARENT" ]] || fail "Safety check failed: could not determine parent disk of '${ROOT_SOURCE_REAL}'."
    ROOT_PARENT="/dev/${ROOT_PARENT}"
    ROOT_PARENT="$(readlink -f "$ROOT_PARENT" 2>/dev/null || echo "$ROOT_PARENT")"
    [[ "$ROOT_PARENT" == "$DISK" ]] || fail "Safety check failed: root filesystem '${ROOT_SOURCE_REAL}' is backed by '${ROOT_PARENT}', not '${DISK}'."
fi

DISK_SIZE_BYTES="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$DISK_SIZE_BYTES" -ge "$MIN_DISK_BYTES" ]] || fail "Target disk '${DISK}' is smaller than 1 GiB."

DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
info "Target disk: ${DISK} (${DISK_SIZE_MB} MiB) — OK"

# ============================================================================
# 10. RAM
# ============================================================================

RAM_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"
[[ -n "$RAM_KB" ]] || fail "Could not determine system RAM."

RAM_MB=$((RAM_KB / 1024))

if (( RAM_MB < MIN_RAM_MB )); then
    fail "Only ${RAM_MB} MiB RAM detected. Minimum allowed: ${MIN_RAM_MB} MiB."
elif (( RAM_MB < RECOMMENDED_RAM_MB )); then
    warn "RAM is ${RAM_MB} MiB. ${RECOMMENDED_RAM_MB} MiB or more is recommended for CHR."
else
    info "RAM: ${RAM_MB} MiB — OK"
fi

# ============================================================================
# 11. Network detection (informational only)
# ============================================================================

info "Detecting network configuration..."

INTERFACE="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
)"

[[ -n "$INTERFACE" ]] || fail "Could not detect the primary IPv4 interface."

ADDR_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null |
    awk '{print $4; exit}'
)"

[[ -n "$ADDR_CIDR" ]] || fail "Could not detect an IPv4 address on '${INTERFACE}'."

IPV4="${ADDR_CIDR%%/*}"
PREFIX="${ADDR_CIDR##*/}"

GATEWAY="$(
    ip -4 route show default dev "$INTERFACE" 2>/dev/null |
    awk '/default/ {print $3; exit}'
)"

[[ -n "$GATEWAY" ]] || fail "Could not detect the IPv4 default gateway."

validate_ipv4() {
    local ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "$ip"

    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1

    return 0
}

validate_ipv4 "$IPV4" || fail "Detected IPv4 '${IPV4}' is invalid."
validate_ipv4 "$GATEWAY" || fail "Detected gateway '${GATEWAY}' is invalid."

[[ "$PREFIX" =~ ^[0-9]+$ ]] || fail "Detected prefix '/${PREFIX}' is invalid."
(( PREFIX >= 1 && PREFIX <= 32 )) || fail "Detected prefix '/${PREFIX}' is out of range."

info "Network: ${INTERFACE}  ${IPV4}/${PREFIX}  gateway ${GATEWAY} — OK"
warn "Network values are detected for information only. This installer does not write network configuration into the CHR image."
warn "IPv6 is not modified by this installer."

# ============================================================================
# 12. Display plan
# ============================================================================

echo
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}         DETECTED CONFIGURATION         ${NC}"
echo -e "${CYAN}========================================${NC}"
echo
echo -e "${WHITE}Ubuntu             : ${GREEN}${VERSION_ID}${NC}"
echo -e "${WHITE}Architecture       : ${GREEN}${ARCH}${NC}"
echo -e "${WHITE}Virtualization     : ${GREEN}${VIRT_TYPE}${NC}"
echo -e "${WHITE}Boot mode          : ${GREEN}Legacy BIOS${NC}"
echo -e "${WHITE}Interface          : ${GREEN}${INTERFACE}${NC}"
echo -e "${WHITE}IPv4               : ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "${WHITE}Gateway            : ${GREEN}${GATEWAY}${NC}"
echo -e "${WHITE}Target disk        : ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk size          : ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}RAM                : ${GREEN}${RAM_MB} MiB${NC}"
echo -e "${WHITE}CHR version        : ${GREEN}${CHR_VERSION}${NC}"
echo

echo -e "${RED}========================================${NC}"
echo -e "${RED}                 WARNING                ${NC}"
echo -e "${RED}========================================${NC}"
echo
echo -e "${YELLOW}This operation will permanently erase:${NC}"
echo -e "${RED}    ${DISK}${NC}"
echo
echo -e "${YELLOW}Ubuntu, all partitions and all data on that disk will be destroyed.${NC}"
echo -e "${RED}THIS CANNOT BE UNDONE.${NC}"
echo

read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || {
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
}

# ============================================================================
# 13. Download CHR
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

[[ -s "$CHR_FILE" ]] || fail "Downloaded CHR archive is empty."

# ============================================================================
# 14. Verify archive
# ============================================================================

info "[2/5] Verifying downloaded archive..."

FILE_TYPE="$(file -b "$CHR_FILE" 2>/dev/null || true)"
case "$FILE_TYPE" in
    Zip\ archive*)
        ;;
    *)
        fail "Downloaded file is not a ZIP archive. Detected type: '${FILE_TYPE}'."
        ;;
esac

unzip -t "$CHR_FILE" >/dev/null || fail "ZIP integrity test failed."

ACTUAL_SHA256="$(sha256sum "$CHR_FILE" | awk '{print $1}')"
DOWNLOAD_SIZE="$(stat -c%s "$CHR_FILE" 2>/dev/null || echo 0)"

[[ "$DOWNLOAD_SIZE" -gt 0 ]] || fail "Downloaded archive has an invalid size."

echo
echo -e "${CYAN}Downloaded file:${NC} ${CHR_FILE}"
echo -e "${CYAN}Size:${NC} ${DOWNLOAD_SIZE} bytes"
echo -e "${CYAN}SHA256:${NC} ${ACTUAL_SHA256}"
echo
echo -e "${YELLOW}Compare this SHA256 with the checksum shown on MikroTik's official CHR page:${NC}"
echo -e "${CYAN}${CHR_INFO_URL}${NC}"
echo

read -r -p "After checking the checksum, type YES to continue: " CONFIRM2
[[ "$CONFIRM2" == "YES" ]] || {
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
}

# ============================================================================
# 15. Extract RAW image from ZIP
# ============================================================================

info "[3/5] Extracting CHR RAW image..."

ZIP_IMAGE_ENTRY="$(
    unzip -Z1 "$CHR_FILE" 2>/dev/null |
    awk '$0 ~ /\.img$/ {print; exit}'
)"

[[ -n "$ZIP_IMAGE_ENTRY" ]] || fail "Could not find a .img file inside the CHR archive."

info "Image inside archive: ${ZIP_IMAGE_ENTRY}"

unzip -p "$CHR_FILE" "$ZIP_IMAGE_ENTRY" > "${WORKDIR}/chr.img" \
    || fail "Failed to extract CHR RAW image."

IMAGE="${WORKDIR}/chr.img"

[[ -s "$IMAGE" ]] || fail "Extracted CHR RAW image is empty."

IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE" 2>/dev/null || echo 0)"
[[ "$IMAGE_SIZE_BYTES" -ge "$MIN_IMAGE_BYTES" ]] || fail "Extracted CHR image is suspiciously small."

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))
info "CHR RAW image size: ${IMAGE_SIZE_MB} MiB"

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB)."
fi

info "CHR image fits inside target disk — OK"

# ============================================================================
# 16. Final confirmation
# ============================================================================

echo
echo -e "${RED}========================================${NC}"
echo -e "${RED}          FINAL DESTRUCTIVE STEP       ${NC}"
echo -e "${RED}========================================${NC}"
echo
echo -e "${WHITE}Target disk : ${GREEN}${DISK}${NC}"
echo -e "${WHITE}Disk size   : ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "${WHITE}CHR image   : ${GREEN}${IMAGE_SIZE_MB} MiB${NC}"
echo -e "${WHITE}IPv4        : ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "${WHITE}Gateway     : ${GREEN}${GATEWAY}${NC}"
echo
echo -e "${YELLOW}The next step will completely overwrite ${DISK}.${NC}"
echo -e "${RED}Ubuntu and all existing data on this disk will be destroyed.${NC}"
echo

read -r -p "Type INSTALL to start writing MikroTik CHR: " FINAL_CONFIRM
[[ "$FINAL_CONFIRM" == "INSTALL" ]] || {
    echo -e "${YELLOW}Installation cancelled. No destructive disk write was performed.${NC}"
    exit 0
}

# ============================================================================
# 17. Final safety checks immediately before dd
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] || fail "Target disk '${DISK}' is no longer available."

FINAL_DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$FINAL_DISK_TYPE" == "disk" ]] || fail "Target '${DISK}' is no longer a whole disk."

FINAL_DISK_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] || fail "Target disk size changed unexpectedly. Refusing to write."

# Confirm root is still on this exact disk immediately before dd.
FINAL_ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$FINAL_ROOT_SOURCE" ]] || fail "Could not re-check the root filesystem."
FINAL_ROOT_REAL="$(readlink -f "$FINAL_ROOT_SOURCE" 2>/dev/null || echo "$FINAL_ROOT_SOURCE")"

FINAL_ROOT_TYPE="$(lsblk -ndo TYPE "$FINAL_ROOT_REAL" 2>/dev/null || true)"

if [[ "$FINAL_ROOT_TYPE" == "disk" ]]; then
    [[ "$FINAL_ROOT_REAL" == "$DISK" ]] || fail "Final safety check failed: root disk changed from '${DISK}'."
else
    FINAL_PARENT="$(lsblk -ndo PKNAME "$FINAL_ROOT_REAL" 2>/dev/null | head -n1 || true)"
    [[ -n "$FINAL_PARENT" ]] || fail "Final safety check failed: could not determine root parent disk."
    FINAL_PARENT="/dev/${FINAL_PARENT}"
    FINAL_PARENT="$(readlink -f "$FINAL_PARENT" 2>/dev/null || echo "$FINAL_PARENT")"
    [[ "$FINAL_PARENT" == "$DISK" ]] || fail "Final safety check failed: root filesystem is backed by '${FINAL_PARENT}', not '${DISK}'."
fi

info "Final disk checks passed."

# ============================================================================
# 18. Destructive write
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
# 19. Cleanup / completion
# ============================================================================

info "[5/5] Cleaning temporary files..."

rm -f \
    "${WORKDIR}/${CHR_FILE}" \
    "${WORKDIR}/chr.img"

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MikroTik CHR Installed           ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${WHITE}CHR Version : ${CYAN}${CHR_VERSION}${NC}"
echo -e "${WHITE}Disk        : ${CYAN}${DISK}${NC}"
echo
echo -e "${YELLOW}Ubuntu has been replaced by MikroTik CHR.${NC}"
echo
echo -e "${CYAN}Next steps:${NC}"
echo
echo -e "${WHITE}1.${NC} Open the VPS VNC / Console from your hosting provider."
echo -e "${WHITE}2.${NC} Boot MikroTik CHR."
echo -e "${WHITE}3.${NC} Log in with the default MikroTik account: ${CYAN}admin${NC} with no password."
echo -e "${WHITE}4.${NC} Configure the CHR network from the console if required."
echo -e "${WHITE}5.${NC} Set a strong unique administrator password immediately."
echo
echo -e "${YELLOW}The installer does NOT create a shared/default administrator password.${NC}"
echo -e "${YELLOW}IPv6 is not configured by this installer.${NC}"
echo -e "${YELLOW}CHR licensing may impose throughput limitations until the required license is applied.${NC}"
echo

read -r -p "Press ENTER to reboot the VPS..." _

sync
sleep 2
reboot
