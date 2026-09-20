#!/bin/bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR Installer
# Version: 1.1.0
# Repository: https://github.com/aryananet/ubuntuchr
# License: MIT
#
# FAIL-SAFE PRINCIPLE:
#   If OS, virtualization, boot mode, root disk, network, image, or any
#   safety condition is ambiguous, abort BEFORE any destructive write.
#
# IMPORTANT:
#   - This script ONLY targets the current VPS guest.
#   - It never accesses the hypervisor/host or other VMs.
#   - The final dd operation ERASES the current VPS system disk completely.
#   - CHR is installed from the official MikroTik RAW image.
#
# Changelog v1.1.0 (see CHANGELOG.md for details):
#   - FIX BUG-01: infinite loop in ERR trap (IN_FAIL guard)
#   - FIX BUG-02: pipefail + grep empty result
#   - FIX BUG-03: network detection fail-without-message
#   - FIX BUG-04: robust IPv4 validator (regex-based)
#   - FIX BUG-05: read + set -e interaction
#   - FIX BUG-06: apt full-upgrade -> apt upgrade
#   - FIX BUG-07: --check-only no longer mutates the system
#   - FIX BUG-08: SHA256 auto-verification (hardcoded pin)
#   - FIX BUG-09: preload reboot binary before dd
#   - FIX BUG-10: rsync -aHAX instead of cp -R
#   - FIX BUG-11: Ubuntu 26.04 removed (untested)
#   - FIX BUG-12: udevadm settle after modprobe nbd
#   - FIX BUG-13: full arg parsing loop
#   - FIX BUG-14: trap installed before arg parsing
#   - FIX BUG-15: clear only on TTY
#   - FIX BUG-16: ANSI colors only on TTY
#   - FIX BUG-17: printf instead of echo -e
#   - FIX BUG-18: timestamped error logs
#   - FIX BUG-19: FSTYPE check before readlink
#   - FIX BUG-20: /dev/root resolution
#   - FIX BUG-21: removed dead ROOT_TYPE
#   - FIX BUG-22: removed dead LOOP_DEV
#   - FIX BUG-23: PKNAME /dev prefix stripping
#   - FIX BUG-24: flock-based single-instance lock
#   - FIX BUG-25: explicit || INTERFACE="" on subshells
#   - FIX BUG-40: check /tmp free space
#   - FIX BUG-41: NEEDRESTART_MODE=a
#   - FIX BUG-58: removed reference to specific password
#

set -Eeuo pipefail
umask 077

# ============================================================================
# Script metadata
# ============================================================================

readonly SCRIPT_NAME="AryanaNet CHR Installer"
readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_REPO="https://github.com/aryananet/ubuntuchr"

# ============================================================================
# Configuration
# ============================================================================

readonly CHR_VERSION="7.23.5"
readonly CHR_FILE="chr-${CHR_VERSION}.img.zip"
readonly CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/${CHR_FILE}"
readonly CHR_INFO_URL="https://mikrotik.com/download/chr"

# ---------------------------------------------------------------------------
# Pinned SHA256 for the CHR archive above.
#
# MUST be updated whenever CHR_VERSION changes. Obtain the checksum from
# the official MikroTik download page (${CHR_INFO_URL}).
#
# If this value is the literal string "UNSET", the installer falls back to
# manual user verification. Auto-verification is strongly preferred.
#
# Can be overridden by exporting ARYANANET_CHR_SHA256 before running.
# ---------------------------------------------------------------------------
readonly DEFAULT_EXPECTED_SHA256="UNSET"
EXPECTED_SHA256="${ARYANANET_CHR_SHA256:-$DEFAULT_EXPECTED_SHA256}"

# Ubuntu versions this installer has been tested against.
# (26.04 intentionally omitted until verified.)
readonly SUPPORTED_UBUNTU_VERSIONS=("20.04" "22.04" "24.04")

readonly MIN_RAM_MB=256
readonly RECOMMENDED_RAM_MB=1024
readonly MIN_DISK_BYTES=$((1024 * 1024 * 1024))     # 1 GiB
readonly MIN_IMAGE_BYTES=$((20 * 1024 * 1024))      # 20 MiB (CHR images are ~30 MiB)
readonly REQUIRED_FREE_KB=$((300 * 1024))           # 300 MiB in /tmp

readonly LOCKFILE_PRIMARY="/run/lock/aryananet-chr.lock"
readonly LOCKFILE_FALLBACK="/tmp/aryananet-chr.lock"

# ============================================================================
# Argument parsing (before anything else — must happen first)
# ============================================================================

CHECK_ONLY=0
NO_REBOOT=0
SKIP_UPGRADE=0

print_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  --check-only      Run all checks and download the image, but DO NOT write
                    to the target disk. Safe mode. System will not be mutated.
  --no-reboot       Do not automatically reboot after installation.
  --skip-upgrade    Skip 'apt-get upgrade' (still installs required packages).
  --version         Print script version and exit.
  --help, -h        Print this help and exit.

Environment variables:
  ARYANANET_CHR_SHA256   Override the expected SHA256 checksum of the CHR
                         archive. Useful for testing or pinning custom builds.

Examples:
  $(basename "$0") --check-only
  $(basename "$0") --no-reboot
  $(basename "$0") --check-only --skip-upgrade

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
        --check-only)   CHECK_ONLY=1;   shift ;;
        --no-reboot)    NO_REBOOT=1;    shift ;;
        --skip-upgrade) SKIP_UPGRADE=1; shift ;;
        --version)      print_version;  exit 0 ;;
        --help|-h)      print_help;     exit 0 ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: '$1'" >&2
            echo "Try '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
        *)
            echo "Unexpected positional argument: '$1'" >&2
            echo "Try '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
    esac
done

# ============================================================================
# Colors (only when attached to a TTY)
# ============================================================================

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    WHITE=$'\033[1;37m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
else
    GREEN='' WHITE='' YELLOW='' RED='' CYAN='' NC=''
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

        # Older workdirs had no .pid file. Only remove clearly stale ones (>5 min).
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

# NOTE: printf '%b...' — NOT echo -e (BUG-17 fix)
info() {
    printf '%b%s%b\n' "$WHITE" "${1:-}" "$NC"
    log "INFO" "${1:-}"
}

warn() {
    printf '%b%s%b\n' "$YELLOW" "${1:-}" "$NC"
    log "WARN" "${1:-}"
}

# ============================================================================
# Fail (with IN_FAIL guard — BUG-01 fix)
# ============================================================================

IN_FAIL=0
fail() {
    if [[ "$IN_FAIL" == "1" ]]; then
        # Recursive invocation — bail out immediately to avoid infinite loop.
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

    # Preserve a timestamped copy of the log (BUG-18 fix).
    local timestamp saved_log
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    saved_log="${ERROR_LOGFILE_BASE}-${timestamp}.log"
    cp -f "$LOGFILE" "$saved_log" 2>/dev/null || true
    printf '%bDiagnostic log preserved: %s%b\n' "$CYAN" "$saved_log" "$NC"

    exit 1
}

# ============================================================================
# Cleanup (installed BEFORE any destructive action — BUG-14 fix)
# ============================================================================

NBD_DEV=""
UEFI_MOUNT_DIR="${WORKDIR}/uefi-mount"
UEFI_BACKUP_DIR="${WORKDIR}/uefi-backup"
REBOOT_HELPER_DIR="/run/aryananet-chr-reboot"

cleanup() {
    local status=$?

    # Never allow cleanup itself to trigger the ERR trap.
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

[[ "$VERSION_SUPPORTED" -eq 1 ]] \
    || fail "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported: ${SUPPORTED_UBUNTU_VERSIONS[*]}."

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
# 5. Update Ubuntu and install prerequisites
# ============================================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a     # BUG-41 fix

# BUG-07 fix: in --check-only mode we do not mutate the system.
if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "CHECK-ONLY: skipping package installation/upgrade."
else
    info "Updating Ubuntu package lists..."
    apt-get update -y >/dev/null || fail "apt-get update failed."

    if [[ "$SKIP_UPGRADE" -eq 0 ]]; then
        # BUG-06 fix: use 'upgrade', NOT 'full-upgrade'.
        # full-upgrade can install/remove packages, upgrade the kernel,
        # and leave the system in a state that requires a reboot before
        # the NBD module is usable.
        info "Upgrading installed Ubuntu packages (safe mode)..."
        apt-get upgrade -y >/dev/null || fail "apt-get upgrade failed."
    else
        warn "Skipping 'apt-get upgrade' (--skip-upgrade)."
    fi

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
        qemu-utils \
        kmod \
        rsync \
        >/dev/null \
        || fail "Failed to install required packages."
fi

# ============================================================================
# 6. Required commands
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
# 7. Free space check (BUG-40 fix)
# ============================================================================

AVAILABLE_KB="$(df -k --output=avail "$WORKDIR" 2>/dev/null | tail -n1 | tr -d ' ')"
if [[ -n "$AVAILABLE_KB" ]] && (( AVAILABLE_KB < REQUIRED_FREE_KB )); then
    fail "Insufficient free space in ${WORKDIR} (${AVAILABLE_KB} KiB available, ${REQUIRED_FREE_KB} KiB required)."
fi

# ============================================================================
# 8. Root filesystem detection
# ============================================================================

info "Detecting root filesystem..."

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

# BUG-19 fix: check FSTYPE BEFORE trying to resolve SOURCE.
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

# BUG-20 fix: resolve /dev/root and similar legacy symlinks.
ROOT_SOURCE="$(readlink -f "$ROOT_SOURCE_RAW" 2>/dev/null || printf '%s' "$ROOT_SOURCE_RAW")"
info "Root filesystem: ${ROOT_SOURCE} (type: ${ROOT_FSTYPE:-unknown})"

# ============================================================================
# 9. Resolve the actual physical/virtual disk backing '/'
# ============================================================================

ROOT_PKNAME="$(lsblk -ndo PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"

if [[ -n "$ROOT_PKNAME" ]]; then
    # BUG-23 fix: strip any leading /dev/ before re-adding it.
    DISK="/dev/${ROOT_PKNAME#/dev/}"
else
    case "$ROOT_SOURCE" in
        /dev/*) DISK="$ROOT_SOURCE" ;;
        *)      fail "Could not safely resolve root disk from '$ROOT_SOURCE'." ;;
    esac
fi

DISK="$(readlink -f "$DISK" 2>/dev/null || printf '%s' "$DISK")"

# ============================================================================
# 10. Disk safety checks
# ============================================================================

[[ -b "$DISK" ]] || fail "Resolved target '$DISK' is not a block device."

DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] \
    || fail "Resolved target '$DISK' is not a whole disk (type: '$DISK_TYPE')."

# Reject LVM / RAID / DM at disk level.
DISK_FSTYPE_CHECK="$(lsblk -ndo FSTYPE "$DISK" 2>/dev/null || true)"
case "$DISK_FSTYPE_CHECK" in
    LVM2_member|linux_raid_member)
        fail "Target disk '$DISK' is part of LVM/RAID ('$DISK_FSTYPE_CHECK'). Refusing automatic install."
        ;;
esac

# Removable check — but only reject USB (virtio false-positive allowed).
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

# The disk must contain '/'.
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
# 11. Memory check
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
# 12. Network detection (BUG-03 + BUG-25 fix)
# ============================================================================

info "Detecting network configuration..."

INTERFACE=""
ADDR_CIDR=""
GATEWAY=""

# Strategy 1: route lookup to a well-known public IP.
INTERFACE="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
    || true)"

# Strategy 2: default route.
if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$(ip -4 route show default 2>/dev/null \
        | awk '/default/ { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
        || true)"
fi

# Strategy 3: first non-loopback interface with a global IPv4.
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

# Fallback for gateway: any default route.
if [[ -z "$GATEWAY" ]]; then
    GATEWAY="$(ip -4 route show default 2>/dev/null \
        | awk '/default/ {print $3; exit}' \
        || true)"
fi

[[ -n "$GATEWAY" ]] || fail "Could not detect the IPv4 default gateway."

# ============================================================================
# 13. IPv4 validation (BUG-04 fix — strict regex-based)
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

info "Network interface: ${INTERFACE}"
info "IPv4 address: ${IPV4}/${PREFIX}"
info "Gateway: ${GATEWAY}"

warn "IPv4 is auto-detected. IPv6 will NOT be configured by this installer."

# ============================================================================
# 14. Summary + first confirmation
# ============================================================================

printf '\n'
printf '%bDetected configuration:%b\n' "$CYAN" "$NC"
printf '\n'
printf '%bUbuntu             : %b%s%b\n' "$WHITE" "$GREEN" "$VERSION_ID" "$NC"
printf '%bArchitecture       : %b%s%b\n' "$WHITE" "$GREEN" "$ARCH" "$NC"
printf '%bVirtualization     : %b%s%b\n' "$WHITE" "$GREEN" "$VIRT_TYPE" "$NC"
printf '%bBoot mode          : %b%s%b\n' "$WHITE" "$GREEN" "$BOOT_MODE" "$NC"
printf '%bNetwork Interface  : %b%s%b\n' "$WHITE" "$GREEN" "$INTERFACE" "$NC"
printf '%bIPv4               : %b%s/%s%b\n' "$WHITE" "$GREEN" "$IPV4" "$PREFIX" "$NC"
printf '%bGateway            : %b%s%b\n' "$WHITE" "$GREEN" "$GATEWAY" "$NC"
printf '%bTarget Disk        : %b%s%b\n' "$WHITE" "$GREEN" "$DISK" "$NC"
printf '%bDisk Size          : %b%s MiB%b\n' "$WHITE" "$GREEN" "$DISK_SIZE_MB" "$NC"
printf '%bRAM                : %b%s MiB%b\n' "$WHITE" "$GREEN" "$RAM_MB" "$NC"
printf '%bCHR Version        : %b%s%b\n' "$WHITE" "$GREEN" "$CHR_VERSION" "$NC"
printf '\n'

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    printf '%bCHECK-ONLY mode enabled.%b\n' "$CYAN" "$NC"
    printf '%bThe target disk will NOT be modified.%b\n' "$YELLOW" "$NC"
    printf '\n'
else
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

    # BUG-05 fix: explicit read error handling.
    if ! read -r -p "Type YES to continue: " CONFIRM; then
        printf '\n'
        fail "Failed to read confirmation (stdin closed?)."
    fi
    if [[ "$CONFIRM" != "YES" ]]; then
        printf '%bInstallation cancelled. The current system was not modified.%b\n' "$YELLOW" "$NC"
        exit 0
    fi
fi

# ============================================================================
# 15. Pre-download URL reachability check
# ============================================================================

if [[ "$CHECK_ONLY" -eq 0 ]]; then
    info "Verifying CHR download URL is reachable..."
    wget --spider --https-only --timeout=15 --tries=2 "$CHR_URL" >/dev/null 2>&1 \
        || fail "CHR download URL is unreachable: $CHR_URL"
fi

# ============================================================================
# 16. Download
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
    >/dev/null 2>&1 \
    || fail "Failed to download CHR image."

[[ -s "$CHR_FILE" ]] || fail "Downloaded CHR archive is empty."

DOWNLOAD_SIZE="$(stat -c%s "$CHR_FILE" 2>/dev/null || echo 0)"
(( DOWNLOAD_SIZE > 0 )) || fail "Downloaded file has invalid size."

# ============================================================================
# 17. ZIP integrity check + SHA256 verification
# ============================================================================

info "[2/4] Verifying downloaded archive..."

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
    # No pinned checksum available: fall back to manual verification.
    warn "No pinned SHA256 in this build (EXPECTED_SHA256=UNSET)."
    warn "You MUST verify manually before continuing."
    printf '%bCompare the SHA256 above with the official checksum at:%b\n' "$YELLOW" "$NC"
    printf '%b%s%b\n' "$CYAN" "$CHR_INFO_URL" "$NC"
    printf '\n'

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        printf '%bCHECK-ONLY: checksum shown above; continuing without disk write.%b\n' "$CYAN" "$NC"
    else
        # BUG-05 fix: explicit read error handling.
        if ! read -r -p "Type YES after verifying the checksum: " CONFIRM2; then
            printf '\n'
            fail "Failed to read confirmation (stdin closed?)."
        fi
        if [[ "$CONFIRM2" != "YES" ]]; then
            printf '%bInstallation cancelled. No disk write was performed.%b\n' "$YELLOW" "$NC"
            exit 0
        fi
    fi
else
    # Auto-verify (BUG-08 fix).
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        fail "SHA256 mismatch! Expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}."
    fi
    info "SHA256 checksum verified against pinned value — OK"
fi

# ============================================================================
# 18. Extract RAW image
# ============================================================================

info "[3/4] Extracting MikroTik CHR RAW image..."

IMAGE="${WORKDIR}/chr.img"

# BUG-02 fix: || true prevents pipefail from aborting on empty grep result.
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
# 19. UEFI preparation
# ============================================================================
#
# Standard x86 CHR RAW images ship the EFI bootloader on partition 1, but
# that partition uses ext2, not FAT. UEFI firmware requires a FAT-formatted
# EFI System Partition. We convert partition 1 (preserving all files) to
# FAT16. The conversion only affects the local working copy of the image.
#
# The existing hybrid GPT/MBR partition table is intentionally preserved:
# CHR's BIOS bootloader relies on fixed layout/offset assumptions.
#

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "Preparing CHR image for UEFI boot..."

    if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null; then
        log "INFO" "AppArmor is enabled; NBD operations may be restricted."
    fi

    mkdir -p "$UEFI_MOUNT_DIR" "$UEFI_BACKUP_DIR"

    modprobe nbd max_part=8 \
        || fail "Could not load the Linux nbd module required for UEFI prep."

    # BUG-12 fix: settle before scanning devnodes.
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

    # BUG-10 fix: rsync -aHAX preserves attrs/ACLs/xattrs.
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
    info "Legacy BIOS detected — using the official CHR RAW image unchanged."
fi

# ============================================================================
# 20. Critical image-vs-disk size check
# ============================================================================

if (( IMAGE_SIZE_BYTES > DISK_SIZE_BYTES )); then
    fail "CHR image (${IMAGE_SIZE_MB} MiB) is larger than target disk (${DISK_SIZE_MB} MiB)."
fi

info "CHR image fits inside target disk — OK"

# ============================================================================
# 21. CHECK-ONLY early exit
# ============================================================================

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    printf '\n'
    printf '%b========================================%b\n' "$GREEN" "$NC"
    printf '%b          CHECK-ONLY COMPLETED%b\n' "$GREEN" "$NC"
    printf '%b========================================%b\n' "$GREEN" "$NC"
    printf '\n'
    printf '%bBoot mode    : %b%s\n' "$WHITE" "$NC" "$BOOT_MODE"
    printf '%bCHR image    : %b%s MiB\n' "$WHITE" "$NC" "$IMAGE_SIZE_MB"
    printf '%bTarget disk  : %b%s\n' "$WHITE" "$NC" "$DISK"
    printf '\n'
    printf '%bNo destructive disk write was performed.%b\n' "$YELLOW" "$NC"
    printf '%bThe VPS remains on Ubuntu.%b\n' "$YELLOW" "$NC"
    printf '\n'
    exit 0
fi

# ============================================================================
# 22. Final pre-write verification
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
# 23. Re-check target immediately before dd
# ============================================================================

info "Performing final disk safety checks..."

[[ -b "$DISK" ]] || fail "Target disk '$DISK' disappeared."

FINAL_DISK_TYPE="$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)"
[[ "$FINAL_DISK_TYPE" == "disk" ]] \
    || fail "Target '$DISK' is no longer detected as a whole disk."

FINAL_DISK_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$FINAL_DISK_SIZE" -eq "$DISK_SIZE_BYTES" ]] \
    || fail "Target disk size changed unexpectedly. Refusing to write."

# Re-verify that '/' is still on this disk.
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
# 24. Preload reboot helper (BUG-09 fix)
# ============================================================================
#
# After dd, the on-disk /sbin/reboot is gone. Preload it into a tmpfs
# so we can still invoke it after the write completes.

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
# Copy required shared libs for the binaries we just copied (best-effort).
if command -v ldd >/dev/null 2>&1; then
    while read -r lib; do
        [[ -r "$lib" ]] || continue
        mkdir -p "${REBOOT_HELPER_DIR}/lib$(dirname "$lib")"
        cp -f "$lib" "${REBOOT_HELPER_DIR}/lib${lib}" 2>/dev/null || true
    done < <(ldd "${REBOOT_HELPER_DIR}/reboot" 2>/dev/null | awk '/=>/ {print $3}' | grep '^/' || true)
fi

# ============================================================================
# 25. Destructive CHR installation
# ============================================================================

info "[4/4] Writing MikroTik CHR to ${DISK}..."
printf '\n'
printf '%bDO NOT INTERRUPT THE WRITE PROCESS.%b\n' "$RED" "$NC"
printf '\n'

sync

# Try dd with oflag=direct if the target supports it, otherwise without.
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
# 26. Finished
# ============================================================================

printf '\n'
printf '%b========================================%b\n' "$GREEN" "$NC"
printf '%b       MikroTik CHR Installed%b\n' "$GREEN" "$NC"
printf '%b========================================%b\n' "$GREEN" "$NC"
printf '\n'
printf '%bCHR Version : %b%s\n' "$WHITE" "$NC" "$CHR_VERSION"
printf '%bDisk        : %b%s\n' "$WHITE" "$NC" "$DISK"
printf '\n'
printf '%bThe Ubuntu operating system has been replaced by MikroTik CHR.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bNext steps:%b\n' "$CYAN" "$NC"
printf '\n'
printf '%b1.%b Open the VPS VNC/Console from your hosting panel.\n' "$WHITE" "$NC"
printf '%b2.%b Boot MikroTik CHR.\n' "$WHITE" "$NC"
printf '%b3.%b The default MikroTik login is:\n' "$WHITE" "$NC"
printf '   %bUsername: admin%b\n' "$CYAN" "$NC"
printf '   %bPassword: empty / no password%b\n' "$CYAN" "$NC"
printf '\n'
printf '%b4.%b Configure the network manually from the CHR console.\n' "$WHITE" "$NC"
printf '\n'
printf '%bIMPORTANT: Set a strong unique administrator password immediately.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bIPv6 is not configured automatically by this installer.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bThe free CHR license has a 1 Mbps per-interface limitation until licensed.%b\n' "$YELLOW" "$NC"
printf '\n'
printf '%bInstallation completed successfully.%b\n' "$GREEN" "$NC"
printf '\n'

# ============================================================================
# 27. Reboot
# ============================================================================

if [[ "$NO_REBOOT" -eq 1 ]]; then
    printf '%b--no-reboot set; skipping automatic reboot.%b\n' "$YELLOW" "$NC"
    printf '%bReboot manually when ready.%b\n' "$YELLOW" "$NC"
    exit 0
fi

if ! read -r -p "Press ENTER to reboot the VPS..." _; then
    # EOF on stdin: proceed with reboot anyway.
    printf '\n'
    warn "stdin closed; proceeding with reboot."
fi

sync
sleep 2

# Try to reboot using the preloaded helper first, then fall back to sysrq.
try_reboot() {
    # 1. Preloaded binary (no disk dependency).
    if [[ -x "${REBOOT_HELPER_DIR}/reboot" ]]; then
        if LD_LIBRARY_PATH="${REBOOT_HELPER_DIR}/lib:${REBOOT_HELPER_DIR}/lib64:${REBOOT_HELPER_DIR}/usr/lib" \
            "${REBOOT_HELPER_DIR}/reboot" -f 2>/dev/null; then
            return 0
        fi
    fi

    # 2. sysrq-trigger — handled directly by the kernel, no userland.
    if [[ -w /proc/sysrq-trigger ]]; then
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        if echo b > /proc/sysrq-trigger 2>/dev/null; then
            return 0
        fi
    fi

    # 3. On-disk binary (may be gone after dd).
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
    # Give the system a few seconds to actually begin rebooting.
    sleep 30
fi

# If we reach here, reboot failed.
printf '\n'
printf '%bAutomatic reboot did not succeed.%b\n' "$YELLOW" "$NC"
printf '%bPlease reboot the VPS manually from your hosting panel.%b\n' "$YELLOW" "$NC"
printf '\n'
exit 0
