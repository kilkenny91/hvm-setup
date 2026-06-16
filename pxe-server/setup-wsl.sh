#!/bin/bash
# =============================================================================
# WSL2-spezifische Hinweise und optionale Netzwerk-Konfiguration
# Führt setup-pxe-server.sh mit WSL-spezifischen Checks aus
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  HPE HVM PXE - WSL2 Setup Assistent"
echo "=========================================="
echo ""

# WSL erkennen
if grep -qi microsoft /proc/version 2>/dev/null; then
    echo -e "${YELLOW}WSL2 erkannt.${NC}"
    echo ""
    echo "Wichtige Hinweise für WSL2 als PXE-Server:"
    echo ""
    echo "  1. NAT-Networking: DHCP-Anfragen von externen Hosts erreichen"
    echo "     WSL2 standardmäßig NICHT. Bridged Networking erforderlich."
    echo ""
    echo "  2. Empfehlung: Hyper-V VM oder VMware VM mit Linux für PXE-Server"
    echo ""
    echo "  3. Alternative: WSL2 mit port forwarding (nur für Tests):"
    echo "     netsh interface portproxy add v4tov4 listenport=67 ..."
    echo ""
    echo "  4. Windows Firewall: UDP 67/68, TCP 80, UDP 69 freigeben"
    echo ""
    read -rp "Trotzdem fortfahren? (y/n) [n]: " cont
    cont="${cont:-n}"
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
else
    echo -e "${GREEN}Native Linux erkannt - optimale Umgebung.${NC}"
fi

# Weiterleitung an Haupt-Setup
exec bash "${SCRIPT_DIR}/setup-pxe-server.sh" "$@"
