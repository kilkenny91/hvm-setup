#!/bin/bash
# =============================================================================
# Führt alle Post-Install Skripte nacheinander aus
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPTS=(
    "00-configure-mgmt-network.sh"
    "01-configure-storage-interfaces.sh"
    "02-configure-iscsi-iqn.sh"
    "03-configure-multipath-iscsi.sh"
    "04-import-hpe-vm-essentials.sh"
    "05-post-install-utils.sh"
    "06-install-ansible.sh"
    "07-setup-ssh-for-ansible.sh"
    "08-deploy-vme-console-deb.sh"
    "09-deploy-ops-vm.sh"
)

echo ""
echo "=========================================="
echo "  HPE HVM Post-Install - Alle Skripte"
echo "=========================================="
echo ""
echo "Folgende Skripte werden ausgeführt:"
for s in "${SCRIPTS[@]}"; do
    echo "  - $s"
done
echo ""
read -rp "Alle Skripte ausführen? (y/n) [y]: " confirm
confirm="${confirm:-y}"
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

for script in "${SCRIPTS[@]}"; do
    script_path="${SCRIPT_DIR}/${script}"
    if [[ -f "$script_path" && -x "$script_path" ]]; then
        echo ""
        echo -e "${GREEN}>>> Starte: ${script}${NC}"
        echo "----------------------------------------"
        bash "$script_path" || {
            echo -e "${YELLOW}WARNUNG: ${script} mit Fehler beendet.${NC}"
            read -rp "Fortfahren? (y/n) [y]: " cont
            cont="${cont:-y}"
            [[ "$cont" =~ ^[Yy]$ ]] || exit 1
        }
    else
        echo -e "${YELLOW}Übersprungen (nicht gefunden): ${script}${NC}"
    fi
done

echo ""
echo -e "${GREEN}Alle Post-Install Skripte abgeschlossen.${NC}"
echo "Status: /root/show-hvm-status.sh"
