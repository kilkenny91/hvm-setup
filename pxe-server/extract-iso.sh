#!/bin/bash
# =============================================================================
# Extrahiert Boot-Dateien aus der HPE HVM ISO für PXE/HTTP Boot
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pxe-server.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    ISO_PATH="${PROJECT_ROOT}/iso/hpe-hvm.iso"
    HTTP_ROOT="/var/www/hvm-pxe"
    TFTP_ROOT="/var/lib/tftpboot"
    PXE_SERVER_IP="127.0.0.1"
fi

if [[ ! -f "$ISO_PATH" ]]; then
    log_error "ISO nicht gefunden: $ISO_PATH"
    echo "Bitte HPE HVM ISO nach $ISO_PATH kopieren."
    exit 1
fi

MOUNT_POINT=$(mktemp -d)
cleanup() { umount "$MOUNT_POINT" 2>/dev/null || true; rmdir "$MOUNT_POINT" 2>/dev/null || true; }
trap cleanup EXIT

log_info "Mounte ISO: $ISO_PATH"
mount -o loop,ro "$ISO_PATH" "$MOUNT_POINT"

mkdir -p "${HTTP_ROOT}/boot/casper"
mkdir -p "${HTTP_ROOT}/iso"
mkdir -p "${TFTP_ROOT}/hvm"

# Boot-Kernel und Initrd (Ubuntu/Subiquity casper)
if [[ -f "${MOUNT_POINT}/casper/vmlinuz" ]]; then
    cp "${MOUNT_POINT}/casper/vmlinuz" "${HTTP_ROOT}/boot/casper/"
    cp "${MOUNT_POINT}/casper/initrd" "${HTTP_ROOT}/boot/casper/"
    cp "${MOUNT_POINT}/casper/vmlinuz" "${TFTP_ROOT}/hvm/"
    cp "${MOUNT_POINT}/casper/initrd" "${TFTP_ROOT}/hvm/"
    log_info "casper/vmlinuz und initrd kopiert"
elif [[ -f "${MOUNT_POINT}/install/vmlinuz" ]]; then
    cp "${MOUNT_POINT}/install/vmlinuz" "${HTTP_ROOT}/boot/casper/vmlinuz"
    cp "${MOUNT_POINT}/install/initrd.gz" "${HTTP_ROOT}/boot/casper/initrd"
    log_info "install/vmlinuz und initrd.gz kopiert"
else
    log_error "Keine Boot-Dateien in ISO gefunden (casper/ oder install/)"
    find "$MOUNT_POINT" -name "vmlinuz" -o -name "initrd*" 2>/dev/null | head -20
    exit 1
fi

# Vollständige ISO für iso-url Parameter verfügbar machen
if [[ ! -f "${HTTP_ROOT}/iso/hpe-hvm.iso" ]]; then
    log_info "Verlinke ISO für HTTP-Zugriff..."
    ln -sf "$ISO_PATH" "${HTTP_ROOT}/iso/hpe-hvm.iso"
fi

# Kernel-Parameter in iPXE aktualisieren
IPXE_BOOT="${TFTP_ROOT}/ipxe/boot.ipxe"
if [[ -f "$IPXE_BOOT" ]]; then
    sed -i "s|@ISO_URL@|http://${PXE_SERVER_IP}/iso/hpe-hvm.iso|g" "$IPXE_BOOT"
    sed -i "s|@KERNEL_URL@|http://${PXE_SERVER_IP}/boot/casper/vmlinuz|g" "$IPXE_BOOT"
    sed -i "s|@INITRD_URL@|http://${PXE_SERVER_IP}/boot/casper/initrd|g" "$IPXE_BOOT"
fi

log_info "ISO-Extraktion abgeschlossen."
log_info "Boot-URL: http://${PXE_SERVER_IP}/boot/casper/vmlinuz"
