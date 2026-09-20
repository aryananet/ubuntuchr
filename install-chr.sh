#!/bin/bash
#
# ============================================================================
#  AryanaNet Enterprise — Ubuntu VPS → MikroTik CHR Installer
# ============================================================================
#
#  Designed for production use by organizations and service providers.
#
#  Design principles:
#    • Fail-closed: any ambiguity aborts BEFORE any destructive write
#    • Network configuration is injected automatically (autorun.scr)
#    • Administrator password is mandatory and must be strong
#    • Dangerous services are disabled by default
#    • Only the current VPS guest disk is targeted — never the host
#    • Official MikroTik RAW image is used exclusively
#
#  Supported:
#    Ubuntu 20.04 / 22.04 / 24.04  (x86_64)
#    Virtualization: KVM, QEMU, Xen, VMware, Hyper-V, Amazon
#    Boot modes: Legacy BIOS and UEFI
#
#  Usage:
#    curl -fsSL <url> | sudo bash
#    sudo bash install-chr.sh
#    sudo bash install-chr.sh --check-only
#    sudo CHR_VERSION=7.24.4 bash install-chr.sh
#
#  Environment variables (optional):
#    CHR_VERSION          RouterOS version (default: 7.23.7 long-term)
#    CHR_IDENTITY         System identity / hostname
#    CHR_DNS1             Primary DNS (default: 1.1.1.1)
#    CHR_DNS2             Secondary DNS (default: 8.8.8.8)
#    DISABLE_SERVICES     Comma-separated list (default: telnet,ftp,www,api,api-ssl)
#
# ============================================================================

set -Eeuo pipefail
umask 077

# ============================================================================
# Configuration
# ============================================================================

# Default to current Long-Term release (safer for production)
DEFAULT_CHR_VERSION="7.23.7"

CHR_VERSION="${CHR_VERSION:-$DEFAULT_CHR_VERSION}"
CHR_FILE="chr-${CHR_VERSION}.img.zip"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/${CHR_FILE}"
CHR_INFO_URL="https://mikrotik.com/download/chr"

SUPPORTED_UBUNTU_VERSIONS=("20.04" "22.04" "24.04")

MIN_RAM_MB=256
RECOMMENDED_RAM_MB=1024
MIN_DISK_BYTES=$((1024 * 1024 * 1024))   # 1 GiB

# Default services to disable for security hardening
DEFAULT_DISABLE_SERVICES="telnet,ftp,www,api,api-ssl"
DISABLE_SERVICES="${DISABLE_SERVICES:-$DEFAULT_DISABLE_SERVICES}"

CHR_DNS1="${CHR_DNS1:-1.1.1.1}"
CHR_DNS2="${CHR_DNS2:-8.8.8.8}"

# ============================================================================
# Working directory & logging
# ============================================================================

WORKDIR="$(mktemp -d /tmp/aryananet-chr.XXXXXXXX)"
LOGFILE="${WORKDIR}/install.log"
UEFI_MOUNT_DIR="${WORKDIR}/uefi-mount"
UEFI_BACKUP_DIR="${WORKDIR}/uefi-backup"
AUTORUN_FILE="${WORKDIR}/autorun.scr"

# ============================================================================
# Colors
# ============================================================================

GREEN='\033[0;32m'
WHITE='\033[1;37m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# Logging helpers
# ============================================================================

log() {
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOGFILE"
}

info() {
    echo -e "${WHITE}$1${NC}"
    log "INFO" "$1"
}

ok() {
    echo -e "${GREEN}✓ $1${NC}"
    log "OK" "$1"
}

warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log "WARN" "$1"
}

fail() {
    local reason="$1"
    echo
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  ABORTED — no destructive write performed${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "${WHITE}Reason: ${reason}${NC}"
    echo
    log "FAIL" "$reason"
    echo -e "${CYAN}Diagnostic log: ${LOGFILE}${NC}"
    echo
    exit 1
}

# ============================================================================
# Argument parsing
# ============================================================================

CHECK_ONLY=0
case "${1:-}" in
    "")
        ;;
    "--check-only")
        CHECK_ONLY=1
        ;;
    "-h"|"--help")
        cat <<EOF
AryanaNet Enterprise CHR Installer

Usage:
  sudo bash install-chr.sh              Full installation
  sudo bash install-chr.sh --check-only Safety checks only (no download/write)
  sudo CHR_VERSION=7.24.4 bash install-chr.sh

Environment variables:
  CHR_VERSION       RouterOS version (default: ${DEFAULT_CHR_VERSION})
  CHR_IDENTITY      System identity/hostname
  CHR_DNS1          Primary DNS (default: 1.1.1.1)
  CHR_DNS2          Secondary DNS (default: 8.8.8.8)
  DISABLE_SERVICES  Services to disable (default: telnet,ftp,www,api,api-ssl)
EOF
        exit 0
        ;;
    *)
        fail "Unknown argument '$1'. Supported: --check-only, --help"
        ;;
esac

# ============================================================================
# Cleanup
# ============================================================================

LOOP_DEV=""
NBD_DEV=""

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
        LOOP_DEV=""
    fi
    # Secure cleanup of sensitive files
    rm -f \
        "${WORKDIR}/${CHR_FILE}" \
        "${WORKDIR}/chr.img" \
        "${AUTORUN_FILE}" \
        2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "Unexpected error on line ${LINENO}."' ERR

# ============================================================================
# Header
# ============================================================================

clear || true

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  AryanaNet Enterprise CHR Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${WHITE}Target: Replace Ubuntu with MikroTik CHR${NC}"
echo -e "${WHITE}Mode  : ${CHECK_ONLY:+Check-only}${CHECK_ONLY:-Full installation}${NC}"
echo

# ============================================================================
# 1. Root check
# ============================================================================

[[ "$(id -u)" -eq 0 ]] || fail "This installer must be run as root."

# ============================================================================
# 2. Operating system
# ============================================================================

info "Checking operating system..."

[[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release."

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
    || fail "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported: ${SUPPORTED_UBUNTU_VERSIONS[*]}."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] \
    || fail "Unsupported architecture '$ARCH'. Only x86_64 is supported."

ok "Ubuntu ${VERSION_ID} (${ARCH})"

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
    kvm|qemu|xen|vmware|microsoft|bochs|amazon)
        ;;
    none)
        fail "No virtualization detected. This looks like bare metal — refusing."
        ;;
    *)
        fail "Unsupported or unknown virtualization type: '$VIRT_TYPE'."
        ;;
esac

ok "Virtualization: ${VIRT_TYPE}"

# ============================================================================
# 4. Boot mode
# ============================================================================

if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="Legacy BIOS"
fi
ok "Boot mode: ${BOOT_MODE}"

# ============================================================================
# 5. Install minimal prerequisites (no full-upgrade)
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

info "Updating package lists..."
apt-get update -y >/dev/null \
    || fail "apt-get update failed."

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
    >/dev/null \
    || fail "Failed to install required packages."

# ============================================================================
# 6. Required commands
# ============================================================================

REQUIRED_COMMANDS=(
    awk blkid blockdev cp dd file find findmnt gzip ip lsblk
    modprobe mount mkfs.fat qemu-nbd readlink sha256sum sgdisk
    stat sync udevadm umount unzip wget losetup
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

# ============================================================================
# 7. Root filesystem detection
# ============================================================================

info "Detecting root filesystem and target disk..."

ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SOURCE" ]] || fail "Could not determine the root filesystem source."

ROOT_SOURCE="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || echo "$ROOT_SOURCE")"

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
case "$ROOT_FSTYPE" in
    overlay|aufs|squashfs)
        fail "Root filesystem type '$ROOT_FSTYPE' is unsupported."
        ;;
    crypto_LUKS)
        fail "Root filesystem is on LUKS encryption; refusing automatic disk selection."
        ;;
esac

# Resolve physical/virtual disk
ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then
    DISK="/dev/${ROOT_PKNAME}"
else
    case "$ROOT_SOURCE" in
        /dev/*)
            DISK="$ROOT_SOURCE"
            ;;
        *)
            fail "Could not safely resolve root disk from '$ROOT_SOURCE'."
            ;;
    esac
fi

DISK="$(readlink -f "$DISK" 2>/dev/null || echo "$DISK")"

# ============================================================================
# 8. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] || fail "Resolved target '$DISK' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] \
    || fail "Resolved target '$DISK' is not a whole disk (type: '$DISK_TYPE')."

# Reject real USB devices (virtio false-positives are allowed)
RM_FLAG="$(lsblk -ndo RM "$DISK" 2>/dev/null || echo 1)"
if [[ "$RM_FLAG" != "0" ]]; then
    DISK_NAME="$(basename "$DISK")"
    DEVICE_BUS_PATH="$(readlink -f "/sys/block/${DISK_NAME}/device" 2>/dev/null || true)"
    if [[ "$DEVICE_BUS_PATH" == *"/usb"* ]]; then
        fail "Target disk '$DISK' is attached via USB. Refusing destructive operation."
    else
        warn "Target disk reports removable=1 (common virtio false positive). Continuing."
    fi
fi

# Confirm the disk actually contains the root filesystem
ROOT_RELATION=0
while read -r NODE_TYPE NODE_PATH NODE_MOUNT; do
    [[ -n "$NODE_PATH" ]] || continue
    if [[ "$NODE_MOUNT" == "/" ]]; then
        ROOT_RELATION=1
        break
    fi
done < <(lsblk -nrpo TYPE,PATH,MOUNTPOINT "$DISK" 2>/dev/null || true)

[[ "$ROOT_RELATION" -eq 1 ]] \
    || fail "Safety check failed: '$DISK' does not contain the filesystem mounted at '/'."

DISK_SIZE_BYTES="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$DISK_SIZE_BYTES" -gt 0 ]] || fail "Could not determine size of target disk '$DISK'."
[[ "$DISK_SIZE_BYTES" -ge "$MIN_DISK_BYTES" ]] \
    || fail "Target disk '$DISK' is smaller than 1 GiB."

DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
ok "Target disk: ${DISK} (${DISK_SIZE_MB} MiB)"

# ============================================================================
# 9. Memory check
# ============================================================================

RAM_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"
[[ -n "$RAM_KB" ]] || fail "Could not determine system RAM."
RAM_MB=$((RAM_KB / 1024))

if [[ "$RAM_MB" -lt "$MIN_RAM_MB" ]]; then
    fail "Only ${RAM_MB} MiB RAM detected. Minimum required: ${MIN_RAM_MB} MiB."
fi

if [[ "$RAM_MB" -lt "$RECOMMENDED_RAM_MB" ]]; then
    warn "Only ${RAM_MB} MiB RAM. 1024 MiB or more is recommended for production CHR."
else
    ok "RAM: ${RAM_MB} MiB"
fi

# ============================================================================
# 10. Network detection
# ============================================================================

info "Detecting network configuration..."

INTERFACE="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") { print $(i+1); exit }
        }
    }'
)"

[[ -n "$INTERFACE" ]] || fail "Could not detect the primary network interface."

ADDR_CIDR="$(
    ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null |
    awk '{print $4; exit}'
)"
[[ -n "$ADDR_CIDR" ]] || fail "Could not detect an IPv4 address on interface '$INTERFACE'."

IPV4="${ADDR_CIDR%%/*}"
PREFIX="${ADDR_CIDR##*/}"

GATEWAY="$(
    ip -4 route show default dev "$INTERFACE" 2>/dev/null |
    awk '/default/ {print $3; exit}'
)"
[[ -n "$GATEWAY" ]] || fail "Could not detect the IPv4 default gateway."

# Basic validation
ipv4_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    (( a >= 0 && a <= 255 )) || return 1
    (( b >= 0 && b <= 255 )) || return 1
    (( c >= 0 && c <= 255 )) || return 1
    (( d >= 0 && d <= 255 )) || return 1
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ipv4_to_int "$IPV4" >/dev/null || fail "Detected IPv4 '$IPV4' is invalid."
ipv4_to_int "$GATEWAY" >/dev/null || fail "Detected gateway '$GATEWAY' is invalid."

if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || (( PREFIX < 1 || PREFIX > 32 )); then
    fail "Detected prefix '/$PREFIX' is invalid."
fi

ok "Interface: ${INTERFACE}"
ok "IPv4: ${IPV4}/${PREFIX}"
ok "Gateway: ${GATEWAY}"

warn "IPv6 is not configured by this installer."

# ============================================================================
# 11. Administrator password (mandatory & strong)
# ============================================================================

echo
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Administrator Password${NC}"
echo -e "${CYAN}========================================${NC}"
echo
echo -e "${WHITE}A strong password is required for the 'admin' user.${NC}"
echo -e "${WHITE}Requirements:${NC}"
echo -e "  • Minimum 12 characters"
echo -e "  • At least one uppercase letter"
echo -e "  • At least one lowercase letter"
echo -e "  • At least one digit"
echo -e "  • At least one special character"
echo

while true; do
    read -r -s -p "Enter new admin password: " ADMIN_PASSWORD
    echo
    read -r -s -p "Confirm admin password: " ADMIN_PASSWORD_CONFIRM
    echo

    if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
        echo -e "${RED}Passwords do not match. Try again.${NC}"
        continue
    fi

    if [[ ${#ADMIN_PASSWORD} -lt 12 ]]; then
        echo -e "${RED}Password must be at least 12 characters.${NC}"
        continue
    fi

    if ! [[ "$ADMIN_PASSWORD" =~ [A-Z] ]]; then
        echo -e "${RED}Password must contain at least one uppercase letter.${NC}"
        continue
    fi
    if ! [[ "$ADMIN_PASSWORD" =~ [a-z] ]]; then
        echo -e "${RED}Password must contain at least one lowercase letter.${NC}"
        continue
    fi
    if ! [[ "$ADMIN_PASSWORD" =~ [0-9] ]]; then
        echo -e "${RED}Password must contain at least one digit.${NC}"
        continue
    fi
    if ! [[ "$ADMIN_PASSWORD" =~ [^a-zA-Z0-9] ]]; then
        echo -e "${RED}Password must contain at least one special character.${NC}"
        continue
    fi

    # Reject common weak patterns
    if [[ "$ADMIN_PASSWORD" =~ (password|admin|123456|qwerty|mikrotik) ]]; then
        echo -e "${RED}Password contains a common weak pattern. Choose a stronger one.${NC}"
        continue
    fi

    break
done

ok "Administrator password accepted"

# Optional identity
if [[ -z "${CHR_IDENTITY:-}" ]]; then
    echo
    read -r -p "System identity / hostname (optional, press Enter to skip): " CHR_IDENTITY
fi

# ============================================================================
# 12. Summary & confirmations
# ============================================================================

echo
echo -e "${CYAN}Detected configuration:${NC}"
echo
echo -e "  ${WHITE}Ubuntu             :${NC} ${GREEN}${VERSION_ID}${NC}"
echo -e "  ${WHITE}Architecture       :${NC} ${GREEN}${ARCH}${NC}"
echo -e "  ${WHITE}Virtualization     :${NC} ${GREEN}${VIRT_TYPE}${NC}"
echo -e "  ${WHITE}Boot mode          :${NC} ${GREEN}${BOOT_MODE}${NC}"
echo -e "  ${WHITE}Network Interface  :${NC} ${GREEN}${INTERFACE}${NC}"
echo -e "  ${WHITE}IPv4               :${NC} ${GREEN}${IPV4}/${PREFIX}${NC}"
echo -e "  ${WHITE}Gateway            :${NC} ${GREEN}${GATEWAY}${NC}"
echo -e "  ${WHITE}DNS                :${NC} ${GREEN}${CHR_DNS1}, ${CHR_DNS2}${NC}"
echo -e "  ${WHITE}Target Disk        :${NC} ${GREEN}${DISK}${NC}"
echo -e "  ${WHITE}Disk Size          :${NC} ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "  ${WHITE}RAM                :${NC} ${GREEN}${RAM_MB} MiB${NC}"
echo -e "  ${WHITE}CHR Version        :${NC} ${GREEN}${CHR_VERSION}${NC}"
echo -e "  ${WHITE}Identity           :${NC} ${GREEN}${CHR_IDENTITY:-<default>}${NC}"
echo -e "  ${WHITE}Disabled services  :${NC} ${GREEN}${DISABLE_SERVICES}${NC}"
echo

echo -e "${RED}========================================${NC}"
echo -e "${RED}               WARNING${NC}"
echo -e "${RED}========================================${NC}"
echo
echo -e "${YELLOW}THIS OPERATION WILL COMPLETELY ERASE:${NC}"
echo -e "${YELLOW}  ${DISK}${NC}"
echo
echo -e "${YELLOW}The current Ubuntu system, all partitions and data${NC}"
echo -e "${YELLOW}on that disk will be permanently destroyed.${NC}"
echo
echo -e "${RED}This operation cannot be undone.${NC}"
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo -e "${GREEN}--check-only mode: no download or disk write will be performed.${NC}"
    echo
    exit 0
fi

read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || {
    echo -e "${YELLOW}Installation cancelled. No changes were made.${NC}"
    exit 0
}

# ============================================================================
# 13. Download CHR image
# ============================================================================

info "[1/5] Downloading MikroTik CHR ${CHR_VERSION}..."

cd "$WORKDIR"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    --retry-connrefused \
    --show-progress \
    "$CHR_URL" \
    -O "$CHR_FILE" \
    || fail "Failed to download CHR image from ${CHR_URL}."

[[ -s "$CHR_FILE" ]] || fail "Downloaded CHR archive is empty."

DOWNLOAD_SIZE="$(stat -c%s "$CHR_FILE" 2>/dev/null || echo 0)"
[[ "$DOWNLOAD_SIZE" -gt 0 ]] || fail "Downloaded file has invalid size."

# ============================================================================
# 14. ZIP integrity & SHA256
# ============================================================================

info "[2/5] Verifying downloaded archive..."

FILE_TYPE="$(file -b "$CHR_FILE" 2>/dev/null || true)"
case "$FILE_TYPE" in
    Zip\ archive*)
        ;;
    *)
        fail "Downloaded file is not a valid ZIP archive. Detected: '$FILE_TYPE'."
        ;;
esac

unzip -t "$CHR_FILE" >/dev/null || fail "ZIP integrity test failed."

ACTUAL_SHA256="$(sha256sum "$CHR_FILE" | awk '{print $1}')"

echo
echo -e "${CYAN}Downloaded file :${NC} ${CHR_FILE}"
echo -e "${CYAN}Size            :${NC} ${DOWNLOAD_SIZE} bytes"
echo -e "${CYAN}SHA256          :${NC} ${ACTUAL_SHA256}"
echo
echo -e "${YELLOW}For maximum security, compare the SHA256 above with the${NC}"
echo -e "${YELLOW}checksum shown on MikroTik's official download page:${NC}"
echo -e "${CYAN}${CHR_INFO_URL}${NC}"
echo

read -r -p "Type YES after verifying the checksum (or if you accept the risk): " CONFIRM2
[[ "$CONFIRM2" == "YES" ]] || {
    echo -e "${YELLOW}Installation cancelled. No disk write was performed.${NC}"
    exit 0
}

# ============================================================================
# 15. Extract RAW image
# ============================================================================

info "[3/5] Extracting CHR RAW image..."

IMAGE="${WORKDIR}/chr.img"
IMAGE_MEMBER="$({ unzip -Z1 "$CHR_FILE" 2>/dev/null || true; } | grep -i '\.img$' | head -n1)"

[[ -n "$IMAGE_MEMBER" ]] \
    || fail "Could not find a .img file inside the downloaded ZIP archive."

unzip -p "$CHR_FILE" "$IMAGE_MEMBER" > "$IMAGE" \
    || fail "Failed to extract CHR RAW image from ZIP archive."

[[ -s "$IMAGE" ]] || fail "Extracted CHR image is empty."

IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE" 2>/dev/null || echo 0)"
[[ "$IMAGE_SIZE_BYTES" -gt $((50 * 1024 * 1024)) ]] \
    || fail "Extracted CHR image is suspiciously small."

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))
ok "CHR RAW image size: ${IMAGE_SIZE_MB} MiB"

# ============================================================================
# 16. UEFI preparation (if needed)
# ============================================================================

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "Preparing CHR image for UEFI boot..."

    mkdir -p "$UEFI_MOUNT_DIR" "$UEFI_BACKUP_DIR"

    modprobe nbd max_part=8 \
        || fail "Could not load the Linux nbd module required for UEFI preparation."

    for candidate in /dev/nbd*; do
        [[ -b "$candidate" ]] || continue
        candidate_size="$(blockdev --getsize64 "$candidate" 2>/dev/null || echo 0)"
        if [[ "$candidate_size" == "0" ]]; then
            NBD_DEV="$candidate"
            break
        fi
    done

    [[ -n "$NBD_DEV" ]] || fail "Could not find a free NBD device."

    qemu-nbd --connect="$NBD_DEV" --format=raw "$IMAGE" \
        || fail "Failed to attach CHR image to NBD device '${NBD_DEV}'."

    udevadm settle 2>/dev/null || true
    sleep 1

    EFI_PART="${NBD_DEV}p1"
    ROOT_PART="${NBD_DEV}p2"

    [[ -b "$EFI_PART" ]] || fail "UEFI preparation failed: boot partition not detected."
    [[ -b "$ROOT_PART" ]] || fail "UEFI preparation failed: RouterOS partition not detected."

    mount -o ro "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the original CHR boot partition."

    BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f \
        \( -iname 'bootx64.efi' -o -iname 'grubx64.efi' -o -iname 'bootia32.efi' \) \
        -print -quit 2>/dev/null || true)"

    [[ -n "$BOOT_FILE" ]] \
        || fail "The CHR boot partition does not contain a detectable EFI bootloader."

    cp -R "$UEFI_MOUNT_DIR/." "$UEFI_BACKUP_DIR/" \
        || fail "Failed to preserve original CHR boot files."

    umount "$UEFI_MOUNT_DIR" || fail "Failed to unmount original boot partition."

    info "Converting boot partition to FAT16 for UEFI compatibility..."
    mkfs.fat -F 16 "$EFI_PART" >/dev/null \
        || fail "Failed to create FAT16 filesystem on boot partition."

    mount "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the new FAT16 boot partition."

    cp -R "$UEFI_BACKUP_DIR/." "$UEFI_MOUNT_DIR/" \
        || fail "Failed to restore EFI boot files."

    sync

    RESTORED_BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f -iname 'bootx64.efi' -print -quit 2>/dev/null || true)"
    [[ -n "$RESTORED_BOOT_FILE" ]] \
        || fail "UEFI bootloader verification failed after FAT conversion."

    umount "$UEFI_MOUNT_DIR" || fail "Failed to unmount prepared UEFI boot partition."
    sync

    qemu-nbd --disconnect "$NBD_DEV" >/dev/null \
        || fail "Failed to disconnect NBD device."
    NBD_DEV=""

    # Ensure partition 1 is typed as EFI System Partition
    GPT_INFO="$(sgdisk -i 1 "$IMAGE" 2>&1 || true)"
    if ! grep -qi 'Partition GUID code:[[:space:]]*EF00' <<< "$GPT_INFO"; then
        info "Marking partition 1 as EFI System Partition..."
        sgdisk -t 1:EF00 -c 1:'RouterOS Boot' "$IMAGE" >/dev/null \
            || fail "Could not mark partition 1 as EFI System Partition."
    fi

    GPT_INFO_FINAL="$(sgdisk -i 1 "$IMAGE" 2>&1 || true)"
    grep -qi 'Partition GUID code:[[:space:]]*EF00' <<< "$GPT_INFO_FINAL" \
        || fail "UEFI verification failed: partition 1 is not EFI System Partition."

    ok "UEFI-compatible image preparation complete"
else
    ok "Legacy BIOS — using official CHR RAW image unchanged"
fi

# ============================================================================
# 17. Image vs disk size check
# ============================================================================

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB)."
fi
ok "CHR image fits inside target disk"

# ============================================================================
# 18. Generate and inject autorun.scr (network + password + hardening)
# ============================================================================

info "[4/5] Generating and injecting initial configuration..."

# Build the autorun script that RouterOS will execute on first boot
{
    echo "# Generated by AryanaNet Enterprise CHR Installer"
    echo "# $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo

    # Identity
    if [[ -n "${CHR_IDENTITY:-}" ]]; then
        echo "/system identity set name=\"${CHR_IDENTITY}\""
    fi

    # Administrator password
    # Note: special characters in password must be carefully handled
    # We use a method that works with most printable characters
    ESCAPED_PASSWORD="${ADMIN_PASSWORD//\\/\\\\}"
    ESCAPED_PASSWORD="${ESCAPED_PASSWORD//\"/\\\"}"
    echo "/user set [find name=admin] password=\"${ESCAPED_PASSWORD}\""

    # Network configuration
    # RouterOS uses ether1 as the first interface in most virtual environments
    echo "/ip address add address=${IPV4}/${PREFIX} interface=ether1"
    echo "/ip route add gateway=${GATEWAY}"
    echo "/ip dns set servers=${CHR_DNS1},${CHR_DNS2} allow-remote-requests=no"

    # Disable dangerous / unnecessary services
    IFS=',' read -ra SERVICES <<< "$DISABLE_SERVICES"
    for svc in "${SERVICES[@]}"; do
        svc="$(echo "$svc" | xargs)"   # trim
        [[ -n "$svc" ]] || continue
        echo "/ip service disable [find name=${svc}]"
    done

    # Disable bandwidth-test server (can be abused)
    echo "/tool bandwidth-server set enabled=no"

    # Disable MAC-server and MAC-Winbox on all interfaces (security)
    echo "/tool mac-server set allowed-interface-list=none"
    echo "/tool mac-server mac-winbox set allowed-interface-list=none"

    # Optional: set a note
    echo "/system note set show-at-login=yes note=\"Installed by AryanaNet Enterprise CHR Installer\""
} > "$AUTORUN_FILE"

# Inject autorun.scr into the RouterOS partition of the image
# Method: attach with qemu-nbd, mount partition 2, copy file

modprobe nbd max_part=8 2>/dev/null || true

for candidate in /dev/nbd*; do
    [[ -b "$candidate" ]] || continue
    candidate_size="$(blockdev --getsize64 "$candidate" 2>/dev/null || echo 0)"
    if [[ "$candidate_size" == "0" ]]; then
        NBD_DEV="$candidate"
        break
    fi
done

[[ -n "$NBD_DEV" ]] || fail "Could not find a free NBD device for autorun injection."

qemu-nbd --connect="$NBD_DEV" --format=raw "$IMAGE" \
    || fail "Failed to attach image for autorun injection."

udevadm settle 2>/dev/null || true
sleep 1

ROOT_PART="${NBD_DEV}p2"
[[ -b "$ROOT_PART" ]] || fail "RouterOS data partition not found for autorun injection."

# Create temporary mount point
AUTORUN_MOUNT="${WORKDIR}/autorun-mount"
mkdir -p "$AUTORUN_MOUNT"

# Try to mount (CHR partition 2 is usually a simple filesystem)
if ! mount -o rw "$ROOT_PART" "$AUTORUN_MOUNT" 2>/dev/null; then
    # Fallback: some images need different options
    mount -t auto -o rw "$ROOT_PART" "$AUTORUN_MOUNT" \
        || fail "Failed to mount RouterOS partition for autorun injection."
fi

# Place autorun.scr in the root of the RouterOS filesystem
cp "$AUTORUN_FILE" "${AUTORUN_MOUNT}/autorun.scr" \
    || fail "Failed to copy autorun.scr into the image."

sync
umount "$AUTORUN_MOUNT" || fail "Failed to unmount after autorun injection."

qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
NBD_DEV=""

ok "Network configuration and password injected successfully"

# Clear password from memory as much as possible
ADMIN_PASSWORD=""
ADMIN_PASSWORD_CONFIRM=""
ESCAPED_PASSWORD=""

# ============================================================================
# 19. Final confirmation before destructive write
# ============================================================================

echo
echo -e "${RED}========================================${NC}"
echo -e "${RED}       FINAL DESTRUCTIVE STEP${NC}"
echo -e "${RED}========================================${NC}"
echo
echo -e "  ${WHITE}Target disk :${NC} ${GREEN}${DISK}${NC}"
echo -e "  ${WHITE}Disk size   :${NC} ${GREEN}${DISK_SIZE_MB} MiB${NC}"
echo -e "  ${WHITE}CHR image   :${NC} ${GREEN}${IMAGE_SIZE_MB} MiB (${BOOT_MODE})${NC}"
echo -e "  ${WHITE}Network     :${NC} ${GREEN}${IPV4}/${PREFIX} via ${GATEWAY}${NC}"
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
# 20. Final disk safety re-check
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] || fail "Target disk '$DISK' disappeared."

FINAL_DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$FINAL_DISK_TYPE" == "disk" ]] \
    || fail "Target '$DISK' is no longer detected as a whole disk."

FINAL_DISK_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] \
    || fail "Target disk size changed unexpectedly. Refusing to write."

# ============================================================================
# 21. Destructive write
# ============================================================================

info "[5/5] Writing MikroTik CHR image to ${DISK}..."
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
# 22. Finished
# ============================================================================

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}     MikroTik CHR Installed Successfully${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "  ${WHITE}CHR Version :${NC} ${CYAN}${CHR_VERSION}${NC}"
echo -e "  ${WHITE}Disk        :${NC} ${CYAN}${DISK}${NC}"
echo -e "  ${WHITE}IP Address  :${NC} ${CYAN}${IPV4}/${PREFIX}${NC}"
echo -e "  ${WHITE}Gateway     :${NC} ${CYAN}${GATEWAY}${NC}"
echo
echo -e "${YELLOW}The Ubuntu operating system has been replaced by MikroTik CHR.${NC}"
echo
echo -e "${CYAN}Next steps:${NC}"
echo
echo -e "  1. The VPS will reboot automatically."
echo -e "  2. Wait 30–60 seconds for CHR to finish first boot."
echo -e "  3. Connect via Winbox / SSH / WebFig using:"
echo -e "       IP       : ${CYAN}${IPV4}${NC}"
echo -e "       Username : ${CYAN}admin${NC}"
echo -e "       Password : ${CYAN}(the password you entered)${NC}"
echo
echo -e "${YELLOW}Important notes:${NC}"
echo -e "  • Free CHR license is limited to 1 Mbps per interface until licensed."
echo -e "  • IPv6 was not configured automatically."
echo -e "  • Review firewall and services after first login."
echo
echo -e "${GREEN}Installation completed successfully.${NC}"
echo

read -r -p "Press ENTER to reboot the VPS..." _

sync
sleep 2
reboot
