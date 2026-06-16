#!/bin/bash
# =============================================================================
# Host manuell auf dem PXE-Server registrieren (Alternative zur iPXE-Abfrage)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pxe-server.conf"
GENERATE_SCRIPT="${SCRIPT_DIR}/generate-autoinstall.sh"

GREEN='\033[0;32m'
NC='\033[0m'

prompt() {
    local var_name="$1" prompt_text="$2" default_value="${3:-}" input
    if [[ -n "$default_value" ]]; then
        read -rp "${prompt_text} [${default_value}]: " input
        input="${input:-$default_value}"
    else
        read -rp "${prompt_text}: " input
        while [[ -z "$input" ]]; do
            read -rp "${prompt_text} (Pflichtfeld): " input
        done
    fi
    printf -v "$var_name" '%s' "$input"
}

echo ""
echo "=========================================="
echo "  HPE HVM Host registrieren"
echo "=========================================="
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Verfügbare Profile anzeigen
INTERFACES_FILE="${PROJECT_ROOT}/config/interfaces.yaml"
if [[ -f "$INTERFACES_FILE" ]]; then
    echo "Verfügbare Interface-Profile:"
    grep -E '^  [a-zA-Z0-9_-]+:' "$INTERFACES_FILE" | grep -v host_mapping | sed 's/://g' | sed 's/^/  - /'
    echo ""
fi

prompt HOSTNAME "Hostname"
prompt IP_ADDRESS "IP-Adresse (Management)"
prompt NETMASK "Subnetzmaske" "255.255.255.0"
prompt GATEWAY "Gateway"
prompt VLAN_ID "VLAN-ID" "1"
prompt INTERFACE_PROFILE "Interface-Profil" "default"

read -rsp "Root-Passwort für Installation [hvmadmin]: " ROOT_PASSWORD
echo ""
ROOT_PASSWORD="${ROOT_PASSWORD:-hvmadmin}"

export ROOT_PASSWORD

echo ""
echo -e "${GREEN}Generiere Autoinstall-Konfiguration...${NC}"
bash "$GENERATE_SCRIPT" "$HOSTNAME" "$IP_ADDRESS" "$NETMASK" "$GATEWAY" "$VLAN_ID" "$INTERFACE_PROFILE"

echo ""
echo "Host '${HOSTNAME}' registriert."
echo ""
echo "Installation starten:"
echo "  1. Ziel-Server per PXE booten"
echo "  2. Im iPXE-Menü 'HVM installieren (vorregistrierter Host)' wählen"
echo "  3. Hostname eingeben: ${HOSTNAME}"
echo ""

# Optional: MAC-basierte PXELinux Config
read -rp "MAC-Adresse für feste PXE-Zuordnung eingeben (optional, Enter zum Überspringen): " MAC_ADDR
if [[ -n "$MAC_ADDR" ]]; then
    MAC_FILE=$(echo "$MAC_ADDR" | tr '[:upper:]' '[:lower:]' | sed 's/:/-/g')
    TFTP_ROOT="${TFTP_ROOT:-/var/lib/tftpboot}"
    PXE_SERVER_IP="${PXE_SERVER_IP:-$(hostname -I | awk '{print $1}')}"

    cat > "${TFTP_ROOT}/pxelinux.cfg/01-${MAC_FILE}" << EOF
DEFAULT ipxe
LABEL ipxe
    KERNEL ipxe/undionly.kpxe
    APPEND -p ${PXE_SERVER_IP} ipxe/menu.ipxe
EOF
    echo "MAC-basierte PXE-Config erstellt: pxelinux.cfg/01-${MAC_FILE}"
fi
