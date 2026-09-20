#!/bin/bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR Installer
# Version: 1.2.0
# Repository: https://github.com/aryananet/ubuntuchr
# License: MIT
#
# FAIL-SAFE PRINCIPLE:
#   If OS, virtualization, boot mode, root disk, network, image, or any
#   safety condition is ambiguous, abort BEFORE any destructive write.
#
# IMPORTANT:
#   - This script ONLY targets the current VPS guest.
#   - The final dd operation ERASES the current VPS system disk completely.
#   - CHR is installed from the official MikroTik RAW image.
#

set -Eeuo pipefail
umask 077

# ============================================================================
# Script metadata
# ============================================================================

readonly SCRIPT_NAME="AryanaNet CHR Installer"
readonly SCRIPT_VERSION="1.2.0"
readonly SCRIPT_REPO="https://github.com/aryananet/ubuntuchr"

# ============================================================================
# Configuration
# ============================================================================

readonly CHR_VERSION="7.23.5"
readonly CHR_FILE="chr-${CHR_VERSION}.img.zip"
readonly CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/${CHR_FILE}"
readonly CHR_INFO_URL="https://mikrotik.com/download/chr"

# ---------------------------------------------------------------------------
# Pinned SHA256 for the CHR archive.
#
# Set this to the official MikroTik checksum for ${CHR_VERSION} to enable
# automatic verification. If left as "UNSET", the installer will show the
# computed checksum and ask the user to verify manually.
# ---------------------------------------------------------------------------
readonly DEFAULT_EXPECTED_SHA256="UNSET"
EXPECTED_SHA256="${ARYANANET_CHR_SHA256:-$DEFAULT_EXPECTED_SHA256}"

readonly SUPPORTED_UBUNTU_VERSIONS=("20.04" "22.04" "24.04" "26.04")

readonly MIN_RAM_MB=256
readonly RECOMMENDED_RAM_MB=1024
readonly MIN_DISK_BYTES=$((1024 * 1024 * 1024))
readonly MIN_IMAGE_BYTES=$((20 * 1024 * 1024))
readonly REQUIRED_FREE_KB=$((300 * 1024))

readonly LOCKFILE_PRIMARY="/run/lock/aryananet-chr.lock"
readonly LOCKFILE_FALLBACK="/tmp/aryananet-chr.lock"

# ============================================================================
# Argument parsing
# ============================================================================

CHECK_ONLY=0
NO_REBOOT=0
SKIP_UPGRADE=0
FORCE_VERSION=0

print_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  --check-only, --dry-run   Run all checks and download the image, but DO NOT
                            write to the target disk. Safe mode.
  --no-reboot               Do not automatically reboot after installation.
  --skip-upgrade            Skip 'apt-get upgrade' (still installs packages).
  --force-version           Bypass the Ubuntu version check.
  --version                 Print script version and exit.
  --help, -h                Print this help and exit.

Environment variables:
  ARYANANET_CHR_SHA256   Override the expected SHA256 checksum.

WARNING:
  Without --check-only, this script will COMPLETELY ERASE the current system
  disk and install MikroTik CHR. All data on the VPS will be permanently
  destroyed. There is no undo.

EOF
}

print_version() {
    echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "CHR version: ${CHR_VERSION}"
    echo "Repository:  ${SCRIPT_REPO}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only|--dry-run) CHECK_ONLY=1;   shift ;;
        --no-reboot)            NO_REBOOT=1;    shift ;;
        --skip-upgrade)         SKIP_UPGRADE=1; shift ;;
        --force-version)        FORCE_VERSION=1; shift ;;
        --version)              print_version;  exit 0 ;;
        --help|-h)              print_help;     exit 0 ;;
        --)                     shift; break ;;
        -*)
            echo "Unknown option: '$1'" >&2
            echo "Try '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
        *)
            echo "Unexpected positional argument: '$1'" >&2
            exit 2
            ;;
    esac
done

# ============================================================================
# Colors (TTY-only)
# ============================================================================

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    WHITE=$'\033[1;37m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    CYAN=$'\033[0;36m'
    MAGENTA=$'\033[0;35m'
    NC=$'\033[0m'
else
    GREEN='' WHITE='' YELLOW='' RED='' CYAN='' MAGENTA='' NC=''
fi

# ============================================================================
# Single-instance lock
# ============================================================================

LOCKFILE="$LOCKFILE_PRIMARY"
if ! mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null; then
    LOCKFILE="$LOCKFILE_FALLBACK"
fi

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    printf 'Another instance of %s is already running (lock: %s).\n' \
        "$SCRIPT_NAME" "$LOCKFILE" >&2
    exit 1
fi

# ============================================================================
# Temporary working directory
# ============================================================================

readonly STALE_WORKDIR_PREFIX="/tmp/aryananet-chr."
readonly ERROR_LOGFILE_BASE="/tmp/aryananet-chr-error"

cleanup_stale_workdirs() {
    local dir pid pidfile
    local old_nullglob
    old_nullglob="$(shopt -p nullglob || true)"
    shopt -s nullglob

    for dir in "${STALE_WORKDIR_PREFIX}"*; do
        [[ -d "$dir" ]] || continue
        pidfile="${dir}/.pid"

        if [[ -r "$pidfile" ]]; then
            pid="$(cat "$pidfile" 2>/dev/null || true)"
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                printf 'Existing installer process %s is still using %s; preserving it.\n' \
                    "$pid" "$dir"
                continue
            fi
            rm -rf -- "$dir" 2>/dev/null || true
            continue
        fi

        if find "$dir" -maxdepth 0 -mmin +5 -print -quit 2>/dev/null | grep -q .; then
            rm -rf -- "$dir" 2>/dev/null || true
        fi
    done

    eval "$old_nullglob"
}

cleanup_stale_workdirs

WORKDIR="$(mktemp -d /tmp/aryananet-chr.XXXXXXXX)"
readonly LOGFILE="${WORKDIR}/install.log"
printf '%s\n' "$$" > "${WORKDIR}/.pid"

# ============================================================================
# Logging
# ============================================================================

log() {
    printf '%s [%s] %s\n' "$(date '+%F %T')" "${1:-?}" "${2:-}" >> "$LOGFILE"
}

info() {
    printf '%b%s%b\n' "$WHITE" "${1:-}" "$NC"
    log "INFO" "${1:-}"
}

warn() {
    printf '%b%s%b\n' "$YELLOW" "${1:-}" "$NC"
    log "WARN" "${1:-}"
}

# ============================================================================
# Fail (with IN_FAIL guard)
# ============================================================================

IN_FAIL=0
fail() {
    if [[ "$IN_FAIL" == "1" ]]; then
        exit 1
    fi
    IN_FAIL=1
    set +e

    local reason="${1:-Unknown error}"

    printf '\n'
    printf '%b========================================%b\n' "$RED" "$NC"
    printf '%bABORTED — no destructive disk write was performed.%b\n' "$RED" "$NC"
    printf '%b========================================%b\n' "$RED" "$NC"
    printf '%bReason: %s%b\n' "$WHITE" "$reason" "$NC"
    printf '\n'

    log "FAIL" "$reason"

    local timestamp saved_log
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    saved_log="${ERROR_LOGFILE_BASE}-${timestamp}.log"
    cp -f "$LOGFILE" "$saved_log" 2>/dev/null || true
    printf '%bDiagnostic log preserved: %s%b\n' "$CYAN" "$saved_log" "$NC"

    exit 1
}

# ============================================================================
# Cleanup
# ============================================================================

NBD_DEV=""
UEFI_MOUNT_DIR="${WORKDIR}/uefi-mount"
UEFI_BACKUP_DIR="${WORKDIR}/uefi-backup"
REBOOT_HELPER_DIR="/run/aryananet-chr-reboot"

cleanup() {
    local status=$?
    set +e
    trap - ERR EXIT INT TERM

    if [[ -n "${UEFI_MOUNT_DIR:-}" && -d "$UEFI_MOUNT_DIR" ]]; then
        umount "$UEFI_MOUNT_DIR" 2>/dev/null \
            || umount -l "$UEFI_MOUNT_DIR" 2>/dev/null \
            || true
    fi

    if [[ -n "${NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
    fi

    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR" 2>/dev/null || true
    fi

    return "$status"
}

trap cleanup EXIT
trap 'fail "Unexpected error on line ${LINENO}."' ERR
trap 'fail "Interrupted by signal."' INT TERM

# ============================================================================
# Header
# ============================================================================

if [[ -t 1 ]]; then
    clear || true
fi

printf '%b========================================%b\n' "$GREEN" "$NC"
printf '%b   %s%b\n' "$GREEN" "$SCRIPT_NAME" "$NC"
printf '%b          v%s%b\n' "$GREEN" "$SCRIPT_VERSION" "$NC"
printf '%b========================================%b\n' "$GREEN" "$NC"
printf '\n'

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

if [[ "$VERSION_SUPPORTED" -eq 0 ]]; then
    if [[ "$FORCE_VERSION" -eq 1 ]]; then
        warn "Ubuntu ${VERSION_ID:-unknown} not in tested list, but --force-version given."
    else
        fail "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported: ${SUPPORTED_UBUNTU_VERSIONS[*]}. Use --force-version to override."
    fi
fi

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
    kvm|qemu|xen|vmware|microsoft|hyperv|bochs|amazon|oracle|parallels)
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
# 5. Cloud provider detection
# ============================================================================

PROVIDER="unknown"

detect_provider() {
    local dmi_vendor dmi_product
    dmi_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    dmi_product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"

    case "${dmi_vendor,,}${dmi_product,,}" in
        *hetzner*)                       PROVIDER="hetzner" ;;
        *digitalocean*|*digital_ocean*)  PROVIDER="digitalocean" ;;
        *vultr*)                         PROVIDER="vultr" ;;
        *linode*|*akamai*)               PROVIDER="linode" ;;
        *amazon*|*aws*)                  PROVIDER="aws" ;;
        *google*|*gce*)                  PROVIDER="gcp" ;;
        *microsoft*|*azure*)             PROVIDER="azure" ;;
        *ovh*)                           PROVIDER="ovh" ;;
        *scaleway*)                      PROVIDER="scaleway" ;;
        *oracle*)                        PROVIDER="oracle" ;;
        *contabo*)                       PROVIDER="contabo" ;;
    esac

    if [[ "$PROVIDER" == "unknown" ]] && command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 2 -o /dev/null -w '%{http_code}' \
            http://169.254.169.254/hetzner/v1/metadata 2>/dev/null | grep -q '^[24]'; then
            PROVIDER="hetzner"
        fi
    fi
}

detect_provider
info "Cloud provider: ${PROVIDER}"

# ============================================================================
# 6. Update Ubuntu and install prerequisites
# ============================================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "CHECK-ONLY: skipping package installation/upgrade."
else
    info "Updating Ubuntu package lists..."
    apt-get update -y >/dev/null || fail "apt-get update failed."

    if [[ "$SKIP_UPGRADE" -eq 0 ]]; then
        info "Upgrading installed Ubuntu packages (safe mode)..."
        apt-get upgrade -y >/dev/null || fail "apt-get upgrade failed."
    else
        warn "Skipping 'apt-get upgrade' (--skip-upgrade)."
    fi

    info "Installing required utilities..."
    apt-get install -y --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        file \
        gzip \
        iproute2 \
        mount \
        util-linux \
        unzip \
        wget \
        dosfstools \
        qemu-utils \
        kmod \
        rsync \
        >/dev/null \
        || fail "Failed to install required packages."
fi

# ============================================================================
# 7. Required commands
# ============================================================================

BASE_COMMANDS=(
    awk blkid blockdev cp dd file find findmnt gzip grep ip
    lsblk mount readlink sha256sum stat sync umount unzip udevadm wget
)
INSTALL_COMMANDS=(mkfs.fat modprobe qemu-nbd rsync)

for cmd in "${BASE_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "Required command not found: $cmd"
done

if [[ "$CHECK_ONLY" -eq 0 ]]; then
    for cmd in "${INSTALL_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || fail "Required command not found (install phase): $cmd"
    done
fi

# ============================================================================
# 8. Free space check
# ============================================================================

AVAILABLE_KB="$(df -k --output=avail "$WORKDIR" 2>/dev/null | tail -n1 | tr -d ' ')"
if [[ -n "$AVAILABLE_KB" ]] && (( AVAILABLE_KB < REQUIRED_FREE_KB )); then
    fail "Insufficient free space in ${WORKDIR} (${AVAILABLE_KB} KiB available, ${REQUIRED_FREE_KB} KiB required)."
fi

# ============================================================================
# 9. Root filesystem detection
# ============================================================================

info "Detecting root filesystem..."

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

case "$ROOT_FSTYPE" in
    overlay|aufs|squashfs)
        fail "Root filesystem type '$ROOT_FSTYPE' is unsupported."
        ;;
    crypto_LUKS)
        fail "Root filesystem is directly on LUKS; refusing automatic disk selection."
        ;;
esac

ROOT_SOURCE_RAW="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SOURCE_RAW" ]] \
    || fail "Could not determine the root filesystem source."

ROOT_SOURCE="$(readlink -f "$ROOT_SOURCE_RAW" 2>/dev/null || printf '%s' "$ROOT_SOURCE_RAW")"
info "Root filesystem: ${ROOT_SOURCE} (type: ${ROOT_FSTYPE:-unknown})"

# ============================================================================
# 10. Resolve target disk
# ============================================================================

ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then
    DISK="/dev/${ROOT_PKNAME#/dev/}"
else
    case "$ROOT_SOURCE" in
        /dev/*) DISK="$ROOT_SOURCE" ;;
        *)      fail "Could not safely resolve root disk from '$ROOT_SOURCE'." ;;
    esac
fi

DISK="$(readlink -f "$DISK" 2>/dev/null || printf '%s' "$DISK")"

# ============================================================================
# 11. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] || fail "Resolved target '$DISK' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] \
    || fail "Resolved target '$DISK' is not a whole disk (type: '$DISK_TYPE')."

DISK_FSTYPE_CHECK="$(lsblk -ndo FSTYPE "$DISK" 2>/dev/null || true)"
case "$DISK_FSTYPE_CHECK" in
    LVM2_member|linux_raid_member)
        fail "Target disk '$DISK' is part of LVM/RAID ('$DISK_FSTYPE_CHECK'). Refusing automatic install."
        ;;
esac

RM_FLAG="$(lsblk -ndo RM "$DISK" 2>/dev/null || echo 1)"
if [[ "$RM_FLAG" != "0" ]]; then
    DISK_NAME="$(basename "$DISK")"
    DEVICE_BUS_PATH="$(readlink -f "/sys/block/${DISK_NAME}/device" 2>/dev/null || true)"

    if [[ "$DEVICE_BUS_PATH" == *"/usb"* ]]; then
        fail "Target disk '$DISK' is attached via USB and marked removable. Refusing."
    else
        warn "Target disk '$DISK' reports removable=1 but is not a USB device (virtio quirk). Continuing."
    fi
fi

ROOT_RELATION=0
while read -r NODE_TYPE NODE_PATH NODE_MOUNT; do
    [[ -n "$NODE_PATH" ]] || continue
    if [[ "$NODE_MOUNT" == "/" ]]; then
        ROOT_RELATION=1
        break
    fi
done < <(lsblk -nrpo TYPE,PATH,MOUNTPOINT "$DISK" 2>/dev/null || true)

[[ "$ROOT_RELATION" -eq 1 ]] \
    || fail "Safety check failed: '$DISK' does not clearly contain '/'."

DISK_SIZE_BYTES="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$DISK_SIZE_BYTES" -gt 0 ]] \
    || fail "Could not determine size of target disk '$DISK'."
(( DISK_SIZE_BYTES >= MIN_DISK_BYTES )) \
    || fail "Target disk '$DISK' is smaller than 1 GiB."

DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
info "Target disk: ${DISK} (${DISK_SIZE_MB} MiB) — OK"

# ============================================================================
# 12. Memory check
# ============================================================================

RAM_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
[[ -n "$RAM_KB" ]] || fail "Could not determine system RAM."

RAM_MB=$((RAM_KB / 1024))

(( RAM_MB >= MIN_RAM_MB )) \
    || fail "Only ${RAM_MB} MiB RAM detected. Minimum: ${MIN_RAM_MB} MiB."

if (( RAM_MB < RECOMMENDED_RAM_MB )); then
    warn "Only ${RAM_MB} MiB RAM detected. ${RECOMMENDED_RAM_MB} MiB+ is recommended."
else
    info "RAM: ${RAM_MB} MiB — OK"
fi

# ============================================================================
# 13. Network detection
# ============================================================================

info "Detecting network configuration..."

INTERFACE=""
ADDR_CIDR=""
GATEWAY=""

INTERFACE="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
    || true)"

if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$(ip -4 route show default 2>/dev/null \
        | awk '/default/ { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
        || true)"
fi

if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$(ip -o -4 addr show scope global 2>/dev/null \
        | awk '!/ lo / {print $2; exit}' \
        || true)"
fi

[[ -n "$INTERFACE" ]] \
    || fail "Could not detect the primary network interface."

ADDR_CIDR="$(ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null \
    | awk '{print $4; exit}' \
    || true)"

[[ -n "$ADDR_CIDR" ]] \
    || fail "Could not detect an IPv4 address on interface '$INTERFACE'."

IPV4="${ADDR_CIDR%%/*}"
PREFIX="${ADDR_CIDR##*/}"

GATEWAY="$(ip -4 route show default dev "$INTERFACE" 2>/dev/null \
    | awk '/default/ {print $3; exit}' \
    || true)"

if [[ -z "$GATEWAY" ]]; then
    GATEWAY="$(ip -4 route show default 2>/dev/null \
        | awk '/default/ {print $3; exit}' \
        || true)"
fi

[[ -n "$GATEWAY" ]] || fail "Could not detect the IPv4 default gateway."

# ============================================================================
# 14. IPv4 validation
# ============================================================================

validate_ipv4() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1

    local a="${BASH_REMATCH[1]}"
    local b="${BASH_REMATCH[2]}"
    local c="${BASH_REMATCH[3]}"
    local d="${BASH_REMATCH[4]}"

    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    return 0
}

validate_ipv4 "$IPV4"    || fail "Detected IPv4 '$IPV4' is invalid."
validate_ipv4 "$GATEWAY" || fail "Detected gateway '$GATEWAY' is invalid."

if ! [[ "$PREFIX" =~ ^[0-9]+$ ]]; then
    fail "Detected prefix '/$PREFIX' is invalid."
fi
if (( PREFIX < 1 || PREFIX > 32 )); then
    fail "Detected prefix '/$PREFIX' is out of range."
fi

GATEWAY_IS_PRIVATE=0
GW_FIRST_OCTET="${GATEWAY%%.*}"
if (( GW_FIRST_OCTET == 10 )) \
    || (( GW_FIRST_OCTET == 172 )) \
    || (( GW_FIRST_OCTET == 192 )); then
    GATEWAY_IS_PRIVATE=1
fi

info "Network interface: ${INTERFACE}"
info "IPv4 address: ${IPV4}/${PREFIX}"
info "Gateway: ${GATEWAY}"

if [[ "$GATEWAY_IS_PRIVATE" -eq 1 && "$PREFIX" == "32" ]]; then
    warn "Point-to-point setup detected (private gateway + /32)."
    warn "You will need to configure the route manually in CHR."
fi

warn "IPv4 is auto-detected. IPv6 is NOT configured by this installer."

# ============================================================================
# 15. Collect interface MAC
# ============================================================================

INTERFACE_MAC=""
if [[ -r "/sys/class/net/${INTERFACE}/address" ]]; then
    INTERFACE_MAC="$(cat "/sys/class/net/${INTERFACE}/address" 2>/dev/null || true)"
fi

# ============================================================================
# 16. Generate RouterOS post-install script
# ============================================================================

POST_INSTALL_DIR="/tmp/aryananet-chr-post"
mkdir -p "$POST_INSTALL_DIR" 2>/dev/null || true
POST_INSTALL_SCRIPT="${POST_INSTALL_DIR}/chr-post-install.rsc"

CHR_IFACE="ether1"

{
    printf '# MikroTik CHR post-install configuration\n'
    printf '# Generated by %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '# Generated: %s\n' "$(date '+%F %T')"
    printf '# Source host: %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf '# Source provider: %s\n' "$PROVIDER"
    printf '# Source interface: %s (%s)\n' "$INTERFACE" "${INTERFACE_MAC:-unknown}"
    printf '#\n'
    printf '# HOW TO USE:\n'
    printf '#   1. Boot the VPS into CHR.\n'
    printf '#   2. Connect via the hosting panel console.\n'
    printf '#   3. Login as "admin" (no password).\n'
    printf '#   4. Paste the commands below one section at a time.\n'
    printf '#   5. Change the admin password at the end!\n'
    printf '#\n'
    printf '\n'
    printf '# --- Identity ------------------------------------------------------\n'
    printf '/system identity set name=%s\n' "$(hostname 2>/dev/null | tr -c 'A-Za-z0-9-' '-' | cut -c1-32 || echo chr)"
    printf '\n'
    printf '# --- Network interface ---------------------------------------------\n'
    printf '# (CHR names the first NIC "ether1" by default)\n'
    printf '# If the MAC was %s, verify with: /interface print\n' "${INTERFACE_MAC:-unknown}"
    printf '\n'
    printf '# --- IPv4 address --------------------------------------------------\n'
    printf '/ip address add address=%s/%s interface=%s\n' "$IPV4" "$PREFIX" "$CHR_IFACE"
    printf '\n'

    if [[ "$PREFIX" == "32" ]]; then
        printf '# --- Route to gateway (required for /32 point-to-point) ------------\n'
        printf '/ip route add dst-address=%s/32 gateway=%s scope=link\n' "$GATEWAY" "$CHR_IFACE"
        printf '/ip route add gateway=%s\n' "$GATEWAY"
    else
        printf '# --- Default route -------------------------------------------------\n'
        printf '/ip route add gateway=%s\n' "$GATEWAY"
    fi
    printf '\n'
    printf '# --- DNS -----------------------------------------------------------\n'
    printf '/ip dns set servers=1.1.1.1,8.8.8.8 allow-remote-requests=no\n'
    printf '\n'
    printf '# --- Harden services ----------------------------------------------\n'
    printf '/ip service disable telnet,ftp,www,api\n'
    printf '/ip service set ssh port=2222\n'
    printf '/ip service set winbox port=8291 address=0.0.0.0/0\n'
    printf '\n'
    printf '# --- Firewall (basic input protection) -----------------------------\n'
    printf '/ip firewall filter add chain=input connection-state=established,related action=accept comment="allow established"\n'
    printf '/ip firewall filter add chain=input connection-state=invalid action=drop comment="drop invalid"\n'
    printf '/ip firewall filter add chain=input protocol=icmp action=accept comment="allow ICMP"\n'
    printf '/ip firewall filter add chain=input protocol=tcp dst-port=2222 action=accept comment="allow SSH"\n'
    printf '/ip firewall filter add chain=input protocol=udp dst-port=8291 action=accept comment="allow WinBox"\n'
    printf '/ip firewall filter add chain=input action=drop comment="drop everything else"\n'
    printf '\n'
    printf '# --- Set admin password (CHANGE THIS!) -----------------------------\n'
    printf '# Uncomment and replace with a strong password:\n'
    printf '# /user set admin password="YourStrongPasswordHere"\n'
    printf '\n'
    printf '# --- End of script ------------------------------------------------\n'
} > "$POST_INSTALL_SCRIPT"

log "INFO" "Post-install RouterOS script written to $POST_INSTALL_SCRIPT"

# ============================================================================
# 17. Summary
# ============================================================================

printf '\n'
printf '%bDetected configuration:%b\n' "$CYAN" "$NC"
printf '\n'
printf '%bUbuntu             : %b%s%b\n' "$WHITE" "$GREEN" "$VERSION_ID" "$NC"
printf '%bArchitecture       : %b%s%b\n' "$WHITE" "$GREEN" "$ARCH" "$NC"
printf '%bVirtualization     : %b%s%b\n' "$WHITE" "$GREEN" "$VIRT_TYPE" "$NC"
printf '%bCloud provider     : %b%s%b\n' "$WHITE" "$GREEN" "$PROVIDER" "$NC"
printf '%bBoot mode          : %b%s%b\n' "$WHITE" "$GREEN" "$BOOT_MODE" "$NC"
printf '%bNetwork Interface  : %b%s%b\n' "$WHITE" "$GREEN" "$INTERFACE" "$NC"
printf '%bInterface MAC      : %b%s%b\n' "$WHITE" "$GREEN" "${INTERFACE_MAC:-unknown}" "$NC"
printf '%bIPv4               : %b%s/%s%b\n' "$WHITE" "$GREEN" "$IPV4" "$PREFIX" "$NC"
printf '%bGateway            : %b%s%b\n' "$WHITE" "$GREEN" "$GATEWAY" "$NC"
printf '%bTarget Disk        : %b%s%b\n' "$WHITE" "$GREEN" "$DISK" "$NC"
printf '%bDisk Size          : %b%s MiB%b\n' "$WHITE" "$GREEN" "$DISK_SIZE_MB" "$NC"
printf '%bRAM                : %b%s MiB%b\n' "$WHITE" "$GREEN" "$RAM_MB" "$NC"
printf '%bCHR Version        : %b%s%b\n' "$WHITE" "$GREEN" "$CHR_VERSION" "$NC"
printf '\n'

# ============================================================================
# 18. CHECK-ONLY early exit
# ============================================================================

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    printf '%bCHECK-ONLY mode enabled.%b\n' "$CYAN" "$NC"
    printf '%bThe target disk will NOT be modified.%b\n' "$YELLOW" "$NC"
    printf '\n'

    printf '%b========================================%b\n' "$MAGENTA" "$NC"
    printf '%b   SAVE THIS NETWORK INFORMATION!%b\n' "$MAGENTA" "$NC"
    printf '%b========================================%b\n' "$MAGENTA" "$NC"
    printf '\n'
    printf '%bYou will need these values to configure CHR after installation:%b\n' "$WHITE" "$NC"
    printf '\n'
    printf '%b  Provider  : %b%s\n' "$WHITE" "$GREEN" "$PROVIDER"
    printf '%b  IPv4      : %b%s/%s\n' "$WHITE" "$GREEN" "$IPV4" "$PREFIX"
    printf '%b  Gateway   : %b%s\n' "$WHITE" "$GREEN" "$GATEWAY"
    printf '%b  Interface : %b%s\n' "$WHITE" "$GREEN" "$INTERFACE"
    printf '%b  MAC       : %b%s\n' "$WHITE" "$GREEN" "${INTERFACE_MAC:-unknown}"
    printf '\n'
    printf '%bA pre-generated RouterOS script has been written to:%b\n' "$WHITE" "$NC"
    printf '%b  %s%b\n' "$CYAN" "$POST_INSTALL_SCRIPT" "$NC"
    printf '\n'
    printf '%bCopy it somewhere safe now:%b\n' "$WHITE" "$NC"
    printf '%b  cat %s%b\n' "$CYAN" "$POST_INSTALL_SCRIPT" "$NC"
    printf '\n'

    printf '%b========================================%b\n' "$GREEN" "$NC"
    printf '%b          CHECK-ONLY COMPLETED%b\n' "$GREEN" "$NC"
    printf '%b========================================%b\n' "$GREEN" "$NC"
    printf '\n'
    printf '%bThe VPS remains on Ubuntu.%b\n' "$YELLOW" "$NC"
    printf '\n'
    exit 0
fi

# ============================================================================
# 19. First confirmation
# ============================================================================

printf '%b========================================%b\n' "$RED" "$NC"
printf '%b                 WARNING%b\n' "$RED" "$NC"
printf '%b========================================%b\n' "$RED" "$NC"
printf '\n'
printf '%bTHIS OPERATION WILL COMPLETELY ERASE:%b\n' "$YELLOW" "$NC"
printf '%b  %s%b\n' "$YELLOW" "$DISK" "$NC"
printf '\n'
printf '%bThe current Ubuntu OS, files, partitions, and all data on%b\n' "$YELLOW" "$NC"
printf '%bthat disk will be destroyed.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bThis operation cannot be undone.%b\n' "$RED" "$NC"
printf '\n'

if ! read -r -p "Type YES to continue: " CONFIRM; then
    printf '\n'
    fail "Failed to read confirmation (stdin closed?)."
fi
if [[ "$CONFIRM" != "YES" ]]; then
    printf '%bInstallation cancelled. The current system was not modified.%b\n' "$YELLOW" "$NC"
    exit 0
fi

# ============================================================================
# 20. Download URL check
# ============================================================================

info "Verifying CHR download URL is reachable..."
wget --spider --https-only --timeout=15 --tries=2 "$CHR_URL" >/dev/null 2>&1 \
    || fail "CHR download URL is unreachable: $CHR_URL"

# ============================================================================
# 21. Download
# ============================================================================

info "[1/5] Downloading MikroTik CHR ${CHR_VERSION}..."

cd "$WORKDIR"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    --retry-connrefused \
    --server-response \
    "$CHR_URL" \
    -O "$CHR_FILE" \
    >/dev/null 2>&1 \
    || fail "Failed to download CHR image."

[[ -s "$CHR_FILE" ]] || fail "Downloaded CHR archive is empty."

DOWNLOAD_SIZE="$(stat -c%s "$CHR_FILE" 2>/dev/null || echo 0)"
(( DOWNLOAD_SIZE > 0 )) || fail "Downloaded file has invalid size."

# ============================================================================
# 22. ZIP integrity + SHA256
# ============================================================================

info "[2/5] Verifying downloaded archive..."

FILE_TYPE="$(file -b "$CHR_FILE" 2>/dev/null || true)"
case "$FILE_TYPE" in
    Zip\ archive*) ;;
    *) fail "Downloaded file is not a valid ZIP archive. Detected: '$FILE_TYPE'." ;;
esac

unzip -t "$CHR_FILE" >/dev/null || fail "ZIP integrity test failed."

ACTUAL_SHA256="$(sha256sum "$CHR_FILE" | awk '{print $1}')"

printf '\n'
printf '%bDownloaded file: %b%s\n' "$CYAN" "$NC" "$CHR_FILE"
printf '%bSize:            %b%s bytes\n' "$CYAN" "$NC" "$DOWNLOAD_SIZE"
printf '%bSHA256:          %b%s\n' "$CYAN" "$NC" "$ACTUAL_SHA256"
printf '\n'

if [[ "$EXPECTED_SHA256" == "UNSET" ]]; then
    warn "No pinned SHA256 in this build."
    warn "You MUST verify manually before continuing."
    printf '%bCompare with the official checksum at:%b\n' "$YELLOW" "$NC"
    printf '%b%s%b\n' "$CYAN" "$CHR_INFO_URL" "$NC"
    printf '\n'

    if ! read -r -p "Type YES after verifying the checksum: " CONFIRM2; then
        printf '\n'
        fail "Failed to read confirmation (stdin closed?)."
    fi
    if [[ "$CONFIRM2" != "YES" ]]; then
        printf '%bInstallation cancelled. No disk write was performed.%b\n' "$YELLOW" "$NC"
        exit 0
    fi
else
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        fail "SHA256 mismatch! Expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}."
    fi
    info "SHA256 checksum verified against pinned value — OK"
fi

# ============================================================================
# 23. Extract RAW image
# ============================================================================

info "[3/5] Extracting MikroTik CHR RAW image..."

IMAGE="${WORKDIR}/chr.img"

IMAGE_MEMBER="$(
    unzip -Z1 "$CHR_FILE" 2>/dev/null \
        | grep -i '\.img$' \
        | head -n1 \
        || true
)"

[[ -n "$IMAGE_MEMBER" ]] \
    || fail "Could not find a .img file inside the downloaded ZIP archive."

unzip -p "$CHR_FILE" "$IMAGE_MEMBER" > "$IMAGE" \
    || fail "Failed to extract CHR RAW image from ZIP archive."

[[ -s "$IMAGE" ]] || fail "Extracted CHR image is empty."

IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE" 2>/dev/null || echo 0)"
(( IMAGE_SIZE_BYTES > MIN_IMAGE_BYTES )) \
    || fail "Extracted CHR image is suspiciously small (${IMAGE_SIZE_BYTES} bytes)."

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))
info "CHR RAW image size: ${IMAGE_SIZE_MB} MiB"

# ============================================================================
# 24. UEFI preparation
# ============================================================================

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "[4/5] Preparing CHR image for UEFI boot..."

    if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null; then
        log "INFO" "AppArmor is enabled; NBD operations may be restricted."
    fi

    mkdir -p "$UEFI_MOUNT_DIR" "$UEFI_BACKUP_DIR"

    modprobe nbd max_part=8 \
        || fail "Could not load the Linux nbd module required for UEFI prep."

    udevadm settle 2>/dev/null || true
    sleep 1

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
    [[ -b "$EFI_PART" ]] \
        || fail "UEFI preparation failed: boot partition '${EFI_PART}' not detected."

    EFI_FSTYPE="$(blkid -o value -s TYPE "$EFI_PART" 2>/dev/null || true)"
    EFI_PARTTYPE="$(blkid -o value -s PART_ENTRY_TYPE "$EFI_PART" 2>/dev/null || true)"

    info "Original CHR boot partition filesystem: ${EFI_FSTYPE:-unknown}"
    info "CHR boot partition GPT type: ${EFI_PARTTYPE:-unavailable}"

    readonly EXPECTED_ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

    if [[ -n "$EFI_PARTTYPE" ]]; then
        [[ "${EFI_PARTTYPE,,}" == "$EXPECTED_ESP_GUID" ]] \
            || fail "UEFI prep refused: partition 1 has unexpected GPT type '${EFI_PARTTYPE}'."
    else
        warn "GPT type unavailable; validating by filesystem and EFI bootloader contents."
    fi

    [[ "${EFI_FSTYPE,,}" == "ext2" ]] \
        || fail "UEFI prep refused: partition 1 is not ext2 (got '${EFI_FSTYPE:-unknown}')."

    mount -o ro "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the original CHR boot partition."

    BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f \
        \( -path '*/EFI/BOOT/BOOTX64.EFI' -o -iname 'bootx64.efi' \) \
        -print -quit 2>/dev/null || true)"

    [[ -n "$BOOT_FILE" ]] \
        || fail "The CHR boot partition does not contain a detectable x86 EFI bootloader."

    rsync -aHAX --delete "$UEFI_MOUNT_DIR/" "$UEFI_BACKUP_DIR/" \
        || fail "Failed to preserve original CHR boot files before FAT conversion."

    umount "$UEFI_MOUNT_DIR" \
        || fail "Failed to unmount the original CHR boot partition."

    info "Converting CHR boot partition to FAT16 for UEFI..."

    mkfs.fat -F 16 -n "CHRBOOT" "$EFI_PART" >/dev/null \
        || fail "Failed to create FAT16 filesystem on the CHR boot partition."

    mount "$EFI_PART" "$UEFI_MOUNT_DIR" \
        || fail "Failed to mount the new FAT16 boot partition."

    rsync -aHAX --delete "$UEFI_BACKUP_DIR/" "$UEFI_MOUNT_DIR/" \
        || fail "Failed to restore CHR EFI boot files to the FAT16 partition."

    sync

    RESTORED_BOOT_FILE="$(find "$UEFI_MOUNT_DIR" -type f \
        -iname 'bootx64.efi' -print -quit 2>/dev/null || true)"
    [[ -n "$RESTORED_BOOT_FILE" ]] \
        || fail "UEFI bootloader verification failed after FAT16 conversion."

    FINAL_EFI_FSTYPE="$(blkid -o value -s TYPE "$EFI_PART" 2>/dev/null || true)"
    FINAL_EFI_PARTTYPE="$(blkid -o value -s PART_ENTRY_TYPE "$EFI_PART" 2>/dev/null || true)"

    [[ "${FINAL_EFI_FSTYPE,,}" == "vfat" ]] \
        || fail "UEFI filesystem verification failed: expected vfat, got '${FINAL_EFI_FSTYPE:-unknown}'."

    if [[ -n "$FINAL_EFI_PARTTYPE" ]]; then
        [[ "${FINAL_EFI_PARTTYPE,,}" == "$EXPECTED_ESP_GUID" ]] \
            || fail "UEFI partition verification failed: unexpected GPT type '${FINAL_EFI_PARTTYPE}'."
    else
        warn "Final GPT type unavailable; FAT filesystem + EFI bootloader checks passed."
    fi

    umount "$UEFI_MOUNT_DIR" \
        || fail "Failed to unmount the prepared UEFI boot partition."

    sync
    qemu-nbd --disconnect "$NBD_DEV" >/dev/null \
        || fail "Failed to disconnect the prepared image from NBD."
    NBD_DEV=""

    info "UEFI-compatible CHR image preparation — OK"
else
    info "[4/5] Legacy BIOS detected — using the official CHR RAW image unchanged."
fi

# ============================================================================
# 25. Image size check
# ============================================================================

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB)."
fi

info "CHR image fits inside target disk — OK"

# ============================================================================
# 26. SAVE THIS — before destructive write
# ============================================================================

printf '\n'
printf '%b========================================%b\n' "$MAGENTA" "$NC"
printf '%b   SAVE THIS NETWORK INFORMATION!%b\n' "$MAGENTA" "$NC"
printf '%b========================================%b\n' "$MAGENTA" "$NC"
printf '\n'
printf '%bAfter the VPS reboots into CHR, you will NOT have shell access.%b\n' "$YELLOW" "$NC"
printf '%bYou will need these values to configure CHR via its console:%b\n' "$WHITE" "$NC"
printf '\n'
printf '%b  Provider  : %b%s\n' "$WHITE" "$GREEN" "$PROVIDER"
printf '%b  IPv4      : %b%s/%s\n' "$WHITE" "$GREEN" "$IPV4" "$PREFIX"
printf '%b  Gateway   : %b%s\n' "$WHITE" "$GREEN" "$GATEWAY"
printf '%b  Interface : %b%s\n' "$WHITE" "$GREEN" "$INTERFACE"
printf '%b  MAC       : %b%s\n' "$WHITE" "$GREEN" "${INTERFACE_MAC:-unknown}"
printf '\n'

printf '%bA pre-generated RouterOS script has been created:%b\n' "$WHITE" "$NC"
printf '%b  %s%b\n' "$CYAN" "$POST_INSTALL_SCRIPT" "$NC"
printf '\n'
printf '%bReview it now and copy it to your local machine:%b\n' "$WHITE" "$NC"
printf '%b  cat %s%b\n' "$CYAN" "$POST_INSTALL_SCRIPT" "$NC"
printf '\n'
printf '%bThe file WILL BE LOST after the disk is overwritten.%b\n' "$RED" "$NC"
printf '\n'

if ! read -r -p "Type SAVED when you have copied the information above: " SAVED_CONFIRM; then
    printf '\n'
    fail "Failed to read confirmation (stdin closed?)."
fi
if [[ "$SAVED_CONFIRM" != "SAVED" ]]; then
    printf '%bInstallation cancelled. Nothing was written to disk.%b\n' "$YELLOW" "$NC"
    printf '%bYour saved information is still at: %s%b\n' "$CYAN" "$POST_INSTALL_SCRIPT" "$NC"
    exit 0
fi

# ============================================================================
# 27. Final confirmation
# ============================================================================

printf '\n'
printf '%b========================================%b\n' "$RED" "$NC"
printf '%b          FINAL DESTRUCTIVE STEP%b\n' "$RED" "$NC"
printf '%b========================================%b\n' "$RED" "$NC"
printf '\n'
printf '%bTarget disk: %b%s\n' "$WHITE" "$NC" "$DISK"
printf '%bDisk size  : %b%s MiB\n' "$WHITE" "$NC" "$DISK_SIZE_MB"
printf '%bCHR image  : %b%s MiB\n' "$WHITE" "$NC" "$IMAGE_SIZE_MB"
printf '%bNetwork    : %b%s/%s via %s\n' "$WHITE" "$NC" "$IPV4" "$PREFIX" "$GATEWAY"
printf '\n'
printf '%bThe next command will overwrite %s.%b\n' "$RED" "$DISK" "$NC"
printf '%bUbuntu will be destroyed permanently.%b\n' "$RED" "$NC"
printf '\n'

if ! read -r -p "Type INSTALL to start writing CHR: " FINAL_CONFIRM; then
    printf '\n'
    fail "Failed to read confirmation (stdin closed?)."
fi
if [[ "$FINAL_CONFIRM" != "INSTALL" ]]; then
    printf '%bInstallation cancelled. No destructive write was performed.%b\n' "$YELLOW" "$NC"
    exit 0
fi

# ============================================================================
# 28. Final disk re-check
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] || fail "Target disk '$DISK' disappeared."

FINAL_DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$FINAL_DISK_TYPE" == "disk" ]] \
    || fail "Target '$DISK' is no longer detected as a whole disk."

FINAL_DISK_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] \
    || fail "Target disk size changed unexpectedly. Refusing to write."

FINAL_ROOT_RELATION=0
while read -r NODE_TYPE NODE_PATH NODE_MOUNT; do
    [[ -n "$NODE_PATH" ]] || continue
    if [[ "$NODE_MOUNT" == "/" ]]; then
        FINAL_ROOT_RELATION=1
        break
    fi
done < <(lsblk -nrpo TYPE,PATH,MOUNTPOINT "$DISK" 2>/dev/null || true)

[[ "$FINAL_ROOT_RELATION" -eq 1 ]] \
    || fail "Target disk no longer contains '/'. Refusing to write."

# ============================================================================
# 29. Preload reboot helper
# ============================================================================

mkdir -p "$REBOOT_HELPER_DIR" 2>/dev/null || true
for bin in reboot systemctl halt poweroff; do
    src=""
    for dir in /sbin /usr/sbin /bin /usr/bin; do
        if [[ -x "${dir}/${bin}" ]]; then
            src="${dir}/${bin}"
            break
        fi
    done
    [[ -n "$src" ]] || continue
    cp -f "$src" "${REBOOT_HELPER_DIR}/${bin}" 2>/dev/null || true
done

if command -v ldd >/dev/null 2>&1 && [[ -x "${REBOOT_HELPER_DIR}/reboot" ]]; then
    while read -r lib; do
        [[ -r "$lib" ]] || continue
        mkdir -p "${REBOOT_HELPER_DIR}/lib$(dirname "$lib")"
        cp -f "$lib" "${REBOOT_HELPER_DIR}/lib${lib}" 2>/dev/null || true
    done < <(ldd "${REBOOT_HELPER_DIR}/reboot" 2>/dev/null | awk '/=>/ {print $3}' | grep '^/' || true)
fi

# ============================================================================
# 30. Destructive write
# ============================================================================

info "[5/5] Writing MikroTik CHR to ${DISK}..."
printf '\n'
printf '%bDO NOT INTERRUPT THE WRITE PROCESS.%b\n' "$RED" "$NC"
printf '\n'

sync

dd \
    if="$IMAGE" \
    of="$DISK" \
    bs=4M \
    iflag=fullblock \
    status=progress \
    conv=fsync \
    || fail "dd failed while writing CHR to ${DISK}."

sync

# ============================================================================
# 31. Success
# ============================================================================

printf '\n'
printf '%b========================================%b\n' "$GREEN" "$NC"
printf '%b       MikroTik CHR Installed%b\n' "$GREEN" "$NC"
printf '%b========================================%b\n' "$GREEN" "$NC"
printf '\n'
printf '%bCHR Version : %b%s\n' "$WHITE" "$NC" "$CHR_VERSION"
printf '%bDisk        : %b%s\n' "$WHITE" "$NC" "$DISK"
printf '%bProvider    : %b%s\n' "$WHITE" "$NC" "$PROVIDER"
printf '\n'
printf '%bThe Ubuntu operating system has been replaced by MikroTik CHR.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bNext steps:%b\n' "$CYAN" "$NC"
printf '\n'
printf '%b1.%b Open the VPS VNC/Console from your hosting panel.\n' "$WHITE" "$NC"
printf '%b2.%b Boot MikroTik CHR.\n' "$WHITE" "$NC"
printf '%b3.%b Login with:\n' "$WHITE" "$NC"
printf '   %bUsername: admin%b\n' "$CYAN" "$NC"
printf '   %bPassword: (empty — just press Enter)%b\n' "$CYAN" "$NC"
printf '\n'
printf '%b4.%b Paste the pre-generated configuration from the file you saved.\n' "$WHITE" "$NC"
printf '\n'
printf '%bIMPORTANT: Set a strong unique administrator password immediately.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bIPv6 is not configured automatically by this installer.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bThe free CHR license has a 1 Mbps per-interface limitation.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bInstallation completed successfully.%b\n' "$GREEN" "$NC"
printf '\n'

# ============================================================================
# 32. Reboot
# ============================================================================

if [[ "$NO_REBOOT" -eq 1 ]]; then
    printf '%b--no-reboot set; skipping automatic reboot.%b\n' "$YELLOW" "$NC"
    printf '%bReboot manually when ready.%b\n' "$YELLOW" "$NC"
    exit 0
fi

if ! read -r -p "Press ENTER to reboot the VPS..." _; then
    printf '\n'
    warn "stdin closed; proceeding with reboot."
fi

sync
sleep 2

try_reboot() {
    if [[ -x "${REBOOT_HELPER_DIR}/reboot" ]]; then
        if LD_LIBRARY_PATH="${REBOOT_HELPER_DIR}/lib:${REBOOT_HELPER_DIR}/lib64:${REBOOT_HELPER_DIR}/usr/lib" \
            "${REBOOT_HELPER_DIR}/reboot" -f 2>/dev/null; then
            return 0
        fi
    fi

    if [[ -w /proc/sysrq-trigger ]]; then
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        if echo b > /proc/sysrq-trigger 2>/dev/null; then
            return 0
        fi
    fi

    for candidate in /sbin/reboot /usr/sbin/reboot /bin/reboot; do
        if [[ -x "$candidate" ]]; then
            if "$candidate" -f 2>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

if try_reboot; then
    sleep 30
fi

printf '\n'
printf '%bAutomatic reboot did not succeed.%b\n' "$YELLOW" "$NC"
printf '%bPlease reboot the VPS manually from your hosting panel.%b\n' "$YELLOW" "$NC"
printf '\n'
exit 0
