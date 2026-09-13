#!/usr/bin/env bash
#
# AryanaNet — Ubuntu VPS -> MikroTik CHR converter
#
# FAIL-SAFE PRINCIPLE:
#   If OS, architecture, virtualization, firmware, disk, network, image,
#   or any other prerequisite is ambiguous, abort before touching the target disk.
#
# IMPORTANT:
#   This script INSTALLS the official MikroTik CHR RAW image by overwriting
#   the VPS system disk. It does NOT modify the physical host/hypervisor.
#   It must only be used inside a normal full-virtualization VPS.
#
set -Eeuo pipefail
umask 077

CHR_VERSION="7.23.5"
CHR_FILE="chr-${CHR_VERSION}.img.zip"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/${CHR_FILE}"
CHR_INFO_URL="https://mikrotik.com/download/chr"

# Shared bootstrap password is NOT written into the CHR image.
# Keep this only as a reminder for your operational process if desired.
# CHR_DEFAULT_PASSWORD="aryananetX#"

SUPPORTED_UBUNTU_VERSIONS=("20.04" "22.04" "24.04" "26.04")
MIN_RAM_MB=256
RECOMMENDED_RAM_MB=1024
MIN_DISK_BYTES=$((1024 * 1024 * 1024))

WORKDIR="$(mktemp -d /tmp/aryananet-chr.XXXXXXXX)"
LOGFILE="${WORKDIR}/install.log"

GREEN='\033[0;32m'
WHITE='\033[1;37m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[0;36m'
NC='\033[0m'

LOOP_DEV=""
MOUNTED_PART=""
MOUNT_POINT=""

log() {
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOGFILE"
}
info() {
    printf '%b\n' "${WHITE}$1${NC}"
    log INFO "$1"
}
warn() {
    printf '%b\n' "${YELLOW}$1${NC}"
    log WARN "$1"
}
fail() {
    local msg="$1"
    printf '\n%b\n' "${RED}ABORTED — no destructive disk write was performed.${NC}"
    printf '%b\n' "${WHITE}Reason: ${msg}${NC}"
    log FAIL "$msg"
    printf '%b\n' "${CYAN}Diagnostic log: ${LOGFILE}${NC}"
    exit 1
}

cleanup() {
    set +e
    if [[ -n "${MOUNT_POINT:-}" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_DEV:-}" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'fail "Unexpected error on line $LINENO."' ERR

command -v clear >/dev/null 2>&1 && clear || true
printf '%b\n' "${GREEN}========================================${NC}"
printf '%b\n' "${GREEN}   AryanaNet — MikroTik CHR Installer${NC}"
printf '%b\n\n' "${GREEN}========================================${NC}"

[[ "$(id -u)" -eq 0 ]] || fail "Run this installer as root."

# 1. Ubuntu only
[[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Unsupported OS '${ID:-unknown}'. Ubuntu only."

VERSION_SUPPORTED=0
for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
    [[ "${VERSION_ID:-}" == "$v" ]] && VERSION_SUPPORTED=1
done
[[ "$VERSION_SUPPORTED" -eq 1 ]] || fail \
    "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Supported: ${SUPPORTED_UBUNTU_VERSIONS[*]}."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || fail "Unsupported architecture '$ARCH'. x86_64 only."

# 2. Full virtualization only
command -v systemd-detect-virt >/dev/null 2>&1 || \
    fail "systemd-detect-virt is unavailable; refusing to guess the environment."

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
CONTAINER_TYPE="$(systemd-detect-virt --container 2>/dev/null || true)"

[[ "$CONTAINER_TYPE" == "none" ]] || \
    fail "A container environment was detected ('$CONTAINER_TYPE'). Containers are not supported."

case "$VIRT_TYPE" in
    kvm|qemu|xen|vmware|microsoft|bochs|amazon|oracle)
        ;;
    none)
        fail "No virtualization detected. This looks like bare metal."
        ;;
    *)
        fail "Unknown/unsupported virtualization type '$VIRT_TYPE'."
        ;;
esac
info "Virtualization: $VIRT_TYPE — OK"

# 3. BIOS only for the current x86 CHR RAW image
if [[ -d /sys/firmware/efi ]]; then
    fail "The VPS is currently booted in UEFI mode. This installer requires legacy BIOS/CSM for the selected CHR RAW image."
fi
info "Boot mode: legacy BIOS — OK"

# 4. Update Ubuntu packages BEFORE continuing
# NOTE: package updates modify the running Ubuntu installation, but never the
# target disk contents. The installer performs no disk write until after the
# final destructive confirmation below.
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
    iproute2 \
    mount \
    util-linux \
    unzip \
    wget \
    || fail "Required package installation failed."

for cmd in \
    wget unzip losetup blkid lsblk findmnt ip awk dd sync sha256sum \
    file mount umount blockdev stat systemd-detect-virt; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

# 5. RAM
RAM_KIB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"
[[ "$RAM_KIB" =~ ^[0-9]+$ ]] || fail "Could not determine RAM."
RAM_MB=$((RAM_KIB / 1024))
(( RAM_MB >= MIN_RAM_MB )) || fail "Only ${RAM_MB} MiB RAM detected; minimum accepted is ${MIN_RAM_MB} MiB."
(( RAM_MB >= RECOMMENDED_RAM_MB )) || warn "RAM is ${RAM_MB} MiB. 1024 MiB or more is recommended."

# 6. Resolve the disk backing /
ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SOURCE" ]] || fail "Could not determine the root filesystem source."

# Resolve symlinks where possible (e.g. /dev/disk/by-id/... -> /dev/sda1).
ROOT_SOURCE_REAL="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || printf '%s' "$ROOT_SOURCE")"
ROOT_TYPE="$(lsblk -ndo TYPE "$ROOT_SOURCE_REAL" 2>/dev/null || true)"

case "$ROOT_TYPE" in
    lvm|raid*|crypt|zfs|bcache)
        fail "Root filesystem is backed by '$ROOT_TYPE'. Refusing to guess the physical disk."
        ;;
    disk|part)
        ;;
    *)
        fail "Root filesystem source '$ROOT_SOURCE_REAL' has unsupported/unknown block type '$ROOT_TYPE'."
        ;;
esac

# Walk the reverse dependency tree. The final 'disk' entry is the actual
# whole-disk device backing the root filesystem. This is more reliable than
# parsing lsblk's human-oriented MOUNTPOINT columns and works on /dev/sda1,
# /dev/vda1, NVMe partitions, etc.
DISK="$(lsblk -srnpo NAME,TYPE "$ROOT_SOURCE_REAL" 2>/dev/null | awk '$2=="disk" {print $1; exit}')"
[[ -n "$DISK" ]] || fail "Could not resolve the whole disk backing '$ROOT_SOURCE_REAL'."

DISK="$(readlink -f "$DISK" 2>/dev/null || printf '%s' "$DISK")"

[[ -b "$DISK" ]] || fail "Resolved target '$DISK' is not a block device."
[[ "$(lsblk -ndo TYPE "$DISK" 2>/dev/null)" == "disk" ]] || \
    fail "Resolved target '$DISK' is not a whole disk."

# Hard proof: the root source must appear in the dependency tree of the
# selected disk. This avoids ever accepting an unrelated disk.
ROOT_FOUND=0
while read -r node type; do
    [[ "$type" == "part" || "$type" == "disk" || "$type" == "crypt" || "$type" == "lvm" || "$type" == "raid*" ]] || continue
    NODE_REAL="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
    if [[ "$NODE_REAL" == "$ROOT_SOURCE_REAL" ]]; then
        ROOT_FOUND=1
        break
    fi
done < <(lsblk -srnpo NAME,TYPE "$DISK" 2>/dev/null)
(( ROOT_FOUND == 1 )) || fail "Safety check failed: '$DISK' does not clearly contain the root filesystem '$ROOT_SOURCE_REAL'."

DISK_SIZE_BYTES="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$DISK_SIZE_BYTES" =~ ^[0-9]+$ ]] || fail "Could not determine disk size."
(( DISK_SIZE_BYTES >= MIN_DISK_BYTES )) || fail "Target disk is smaller than 1 GiB."

# Refuse removable/optical targets.
DISK_NAME="$(basename "$DISK")"
[[ -r "/sys/class/block/${DISK_NAME}/removable" ]] || fail "Cannot verify whether '$DISK' is removable."
[[ "$(cat "/sys/class/block/${DISK_NAME}/removable")" == "0" ]] || \
    fail "Target disk '$DISK' is marked removable; refusing to erase it."

info "Target disk: $DISK ($((DISK_SIZE_BYTES / 1024 / 1024)) MiB) — OK"

# 7. Network
INTERFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
    { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }')"
[[ -n "$INTERFACE" ]] || fail "Could not detect the primary IPv4 interface."

ADDR_CIDR="$(ip -o -4 addr show dev "$INTERFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
[[ -n "$ADDR_CIDR" ]] || fail "No global IPv4 address detected on '$INTERFACE'."

IPV4="${ADDR_CIDR%/*}"
PREFIX="${ADDR_CIDR#*/}"

GATEWAY="$(ip -4 route show default dev "$INTERFACE" 2>/dev/null | awk '/^default / {print $3; exit}')"
[[ -n "$GATEWAY" ]] || fail "Could not detect the IPv4 default gateway."

valid_ipv4() {
    local ip="$1" octet
    local IFS=.
    read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( octet <= 255 )) || return 1
    done
}
valid_ipv4 "$IPV4" || fail "Detected invalid IPv4 '$IPV4'."
valid_ipv4 "$GATEWAY" || fail "Detected invalid gateway '$GATEWAY'."
[[ "$PREFIX" =~ ^[0-9]{1,2}$ ]] || fail "Invalid IPv4 prefix '/$PREFIX'."
(( PREFIX >= 1 && PREFIX <= 32 )) || fail "Invalid IPv4 prefix '/$PREFIX'."

info "Network: $INTERFACE — $IPV4/$PREFIX — gateway $GATEWAY"

# 8. Download image
cd "$WORKDIR"
info "Downloading official MikroTik CHR ${CHR_VERSION}..."
wget --https-only \
     --secure-protocol=auto \
     --timeout=30 \
     --tries=3 \
     --waitretry=3 \
     --server-response \
     "$CHR_URL" \
     -O "$CHR_FILE" || fail "CHR download failed."

[[ -s "$CHR_FILE" ]] || fail "Downloaded CHR archive is empty."
FILE_TYPE="$(file -b "$CHR_FILE")"
[[ "$FILE_TYPE" == Zip\ archive* ]] || \
    fail "Downloaded file is not a ZIP archive: $FILE_TYPE"

unzip -t "$CHR_FILE" >/dev/null || fail "ZIP integrity test failed."

info "Extracting CHR RAW image..."
ZIP_IMAGE_ENTRY="$(unzip -Z1 "$CHR_FILE" 2>/dev/null | awk '$0 ~ /\.img$/ {print; exit}')"
[[ -n "$ZIP_IMAGE_ENTRY" ]] || fail "The CHR ZIP archive does not contain a RAW .img file."
unzip -p "$CHR_FILE" "$ZIP_IMAGE_ENTRY" > chr.img
[[ -s chr.img ]] || fail "Extracted CHR image is empty."

IMG_SIZE="$(stat -c%s chr.img)"
(( IMG_SIZE > 50 * 1024 * 1024 )) || fail "Extracted image is suspiciously small."
(( IMG_SIZE < DISK_SIZE_BYTES )) || \
    fail "CHR image (${IMG_SIZE} bytes) is not smaller than target disk (${DISK_SIZE_BYTES} bytes). Refusing to write."

# 9. Validate that the RAW image looks like a disk image and inspect partition table.
info "Validating CHR RAW image..."
LOOP_DEV="$(losetup --find --show -P --read-only chr.img)" || \
    fail "Could not attach the CHR image as a loop device."

lsblk -nr "$LOOP_DEV" >/dev/null 2>&1 || fail "CHR image does not expose a valid block layout."

# Ensure it exposes at least one partition or a recognizable disk layout.
PART_COUNT="$(lsblk -ln -o TYPE "$LOOP_DEV" 2>/dev/null | grep -c '^part$' || true)"
(( PART_COUNT >= 1 )) || fail "CHR RAW image has no recognizable partition table; refusing to write."

losetup -d "$LOOP_DEV" || true
LOOP_DEV=""

# 10. Final destructive confirmation.
ARCHIVE_SHA256="$(sha256sum "$CHR_FILE" | awk '{print $1}')"
IMAGE_SHA256="$(sha256sum chr.img | awk '{print $1}')"

printf '\n%b\n' "${CYAN}========================================${NC}"
printf '%b\n' "${RED}FINAL DESTRUCTIVE CONFIRMATION${NC}"
printf '%b\n' "${CYAN}========================================${NC}"
printf '%b\n' "Ubuntu       : ${GREEN}${VERSION_ID}${NC}"
printf '%b\n' "Virtualization: ${GREEN}${VIRT_TYPE}${NC}"
printf '%b\n' "Disk         : ${RED}${DISK}${NC}"
printf '%b\n' "Disk size    : ${GREEN}$((DISK_SIZE_BYTES / 1024 / 1024)) MiB${NC}"
printf '%b\n' "Network      : ${GREEN}${INTERFACE} ${IPV4}/${PREFIX} gw ${GATEWAY}${NC}"
printf '%b\n' "CHR          : ${GREEN}${CHR_VERSION} Long-term${NC}"
printf '%b\n' "ZIP SHA256   : ${GREEN}${ARCHIVE_SHA256}${NC}"
printf '%b\n' "RAW SHA256   : ${GREEN}${IMAGE_SHA256}${NC}"
printf '\n'
printf '%b\n' "${YELLOW}MikroTik official download page:${NC} ${CHR_INFO_URL}"
printf '%b\n' "${YELLOW}This script does NOT use the unofficial/unsupported autorun.scr provisioning method.${NC}"
printf '%b\n' "${YELLOW}After reboot, CHR will require console/management access for initial network/password configuration.${NC}"
printf '\n'
printf '%b\n' "${RED}WARNING: EVERYTHING on ${DISK} will be permanently destroyed.${NC}"
printf '%b\n' "${RED}The previous Ubuntu OS cannot be recovered by this script.${NC}"
printf '\n'

read -r -p "Type INSTALL-CHR to permanently erase ${DISK} and continue: " CONFIRM
[[ "$CONFIRM" == "INSTALL-CHR" ]] || {
    printf '%b\n' "${YELLOW}Installation cancelled. No disk write was performed.${NC}"
    exit 0
}

# 11. Re-check target immediately before dd.
[[ -b "$DISK" ]] || fail "Target disk disappeared."
[[ "$(lsblk -ndo TYPE "$DISK" 2>/dev/null)" == "disk" ]] || fail "Target is no longer a whole disk."
CURRENT_SIZE="$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)"
[[ "$CURRENT_SIZE" == "$DISK_SIZE_BYTES" ]] || fail "Target disk size changed after confirmation."

# The root filesystem is expected to remain mounted because the installer is
# running from the disk that is about to be replaced. Other mountpoints on the
# same system disk are also part of the disk being intentionally replaced; do
# not misclassify them as a different target.

# 12. Destructive write
info "Writing CHR RAW image to ${DISK}..."
warn "DO NOT close the console, power off the VPS, or interrupt dd."
sync

dd if=chr.img of="$DISK" bs=4M iflag=fullblock status=progress conv=fsync

sync
blockdev --rereadpt "$DISK" 2>/dev/null || true
sync

# 13. Cleanup and reboot
rm -f "$CHR_FILE" chr.img

printf '\n%b\n' "${GREEN}========================================${NC}"
printf '%b\n' "${GREEN}       MikroTik CHR Installed${NC}"
printf '%b\n' "${GREEN}========================================${NC}"
printf '%b\n' "CHR version: ${CHR_VERSION}"
printf '\n'
printf '%b\n' "${YELLOW}IMPORTANT:${NC}"
printf '%b\n' "1. Reconnect through your provider's VNC/console after reboot."
printf '%b\n' "2. The current Ubuntu IP/gateway were detected as:"
printf '%b\n' "   ${IPV4}/${PREFIX}  gateway ${GATEWAY}"
printf '%b\n' "3. Configure the CHR network and set a strong unique admin password from the console."
printf '%b\n' "4. Do NOT reuse the old shared password 'aryananetX#' as a permanent production password."
printf '%b\n' "5. IPv6, firewall policy, DNS and provider-specific routing are NOT automatically configured."
printf '%b\n' "6. The free CHR license has a 1 Mbps per-interface upload limitation until licensed."
printf '\n'
printf '%b\n' "${CYAN}Rebooting in 10 seconds...${NC}"
sleep 10
sync
reboot
