#!/bin/bash
# =============================================================================
# Status und Diagnose des PXE-Servers
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pxe-server.conf"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

echo "=== HPE HVM PXE Server Status ==="
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    ok "Konfiguration: $CONFIG_FILE"
else
    warn "Keine Konfiguration gefunden. setup-pxe-server.sh ausführen."
fi

echo ""
echo "--- Dienste ---"
for svc in dnsmasq nginx fcgiwrap; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc läuft"
    else
        fail "$svc nicht aktiv"
    fi
done

echo ""
echo "--- Dateien ---"
TFTP_ROOT="${TFTP_ROOT:-/var/lib/tftpboot}"
HTTP_ROOT="${HTTP_ROOT:-/var/www/hvm-pxe}"
ISO_PATH="${ISO_PATH:-${PROJECT_ROOT}/iso/hpe-hvm.iso}"

[[ -f "${TFTP_ROOT}/pxelinux.0" ]] && ok "pxelinux.0" || fail "pxelinux.0 fehlt"
[[ -f "${TFTP_ROOT}/ipxe/menu.ipxe" ]] && ok "iPXE menu" || fail "iPXE menu fehlt"
[[ -f "${HTTP_ROOT}/boot/casper/vmlinuz" ]] && ok "Kernel (vmlinuz)" || warn "Kernel nicht extrahiert - extract-iso.sh ausführen"
[[ -f "$ISO_PATH" ]] && ok "ISO: $ISO_PATH" || warn "ISO nicht gefunden: $ISO_PATH"

echo ""
echo "--- Registrierte Hosts ---"
if [[ -d "${HTTP_ROOT}/hosts" ]]; then
    ls -1 "${HTTP_ROOT}/hosts/" 2>/dev/null | while read -r host; do
        ok "Host: $host"
    done
    [[ -z "$(ls -A "${HTTP_ROOT}/hosts/" 2>/dev/null)" ]] && warn "Keine Hosts registriert"
fi

echo ""
echo "--- Netzwerk ---"
PXE_SERVER_IP="${PXE_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
echo "  Server IP: ${PXE_SERVER_IP}"
echo "  Test URLs:"
echo "    http://${PXE_SERVER_IP}/boot/casper/vmlinuz"
echo "    http://${PXE_SERVER_IP}/hosts/<hostname>/user-data"
