#!/bin/bash
# =============================================================================
# Script 1: Storage-Interfaces konfigurieren (IP, Subnetzmaske)
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
NETPLAN_FILE="/etc/netplan/99-hvm-storage.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

prompt() {
    local var_name="$1" prompt_text="$2" default_value="${3:-}" input
    if [[ -n "$default_value" ]]; then
        read -rp "${prompt_text} [${default_value}]: " input
        input="${input:-$default_value}"
    else
        read -rp "${prompt_text}: " input
    fi
    printf -v "$var_name" '%s' "$input"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$PARAMS_FILE"
        log_info "Parameter aus $PARAMS_FILE geladen"
    fi
}

netmask_to_cidr() {
    local mask="$1" cidr=0 i1 i2 i3 i4
    IFS=. read -r i1 i2 i3 i4 <<< "$mask"
    for octet in $i1 $i2 $i3 $i4; do
        while [[ $octet -gt 0 ]]; do
            cidr=$((cidr + octet % 2))
            octet=$((octet / 2))
        done
    done
    echo "$cidr"
}

list_interfaces() {
    echo ""
    echo "Verfügbare Netzwerk-Interfaces:"
    ip -br link show | grep -v "^lo" | awk '{print "  " $1 " (" $3 ")"}'
    echo ""
}

configure_storage_interfaces() {
    local storage_ifaces="$1"
    local ethernets=""
    local count=0

    IFS=',' read -ra IFACES <<< "$storage_ifaces"
    for iface in "${IFACES[@]}"; do
        iface=$(echo "$iface" | xargs)
        [[ -z "$iface" ]] && continue

        count=$((count + 1))
        echo ""
        echo "--- Storage Interface ${count}: ${iface} ---"

        local default_ip=""
        if [[ $count -eq 1 ]]; then
            default_ip="${STORAGE_IP1:-}"
        else
            default_ip="${STORAGE_IP2:-}"
        fi

        local s_ip s_mask s_mtu
        prompt s_ip "IP-Adresse für ${iface}" "$default_ip"
        prompt s_mask "Subnetzmaske" "${STORAGE_NETMASK:-255.255.255.0}"
        prompt s_mtu "MTU" "${STORAGE_MTU:-9000}"

        local cidr
        cidr=$(netmask_to_cidr "$s_mask")

        ethernets+="    ${iface}:
      dhcp4: false
      addresses:
        - ${s_ip}/${cidr}
      mtu: ${s_mtu}
"
    done

    if [[ -z "$ethernets" ]]; then
        log_warn "Keine Storage-Interfaces konfiguriert."
        return 1
    fi

    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
${ethernets}
EOF

    log_info "Storage-Netplan erstellt: $NETPLAN_FILE"
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 1: Storage-Interfaces konfigurieren"
    echo "=========================================="

    load_params
    list_interfaces

    prompt STORAGE_INTERFACES "Storage-Interfaces (kommagetrennt)" "${STORAGE_INTERFACES:-}"

    if [[ -z "$STORAGE_INTERFACES" ]]; then
        log_warn "Keine Storage-Interfaces angegeben. Abbruch."
        exit 1
    fi

    configure_storage_interfaces "$STORAGE_INTERFACES"

    echo ""
    read -rp "Konfiguration anwenden? (y/n) [y]: " confirm
    confirm="${confirm:-y}"
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        netplan generate
        netplan apply
        log_info "Storage-Interfaces konfiguriert."
        ip -br addr | grep -v "^lo"
    fi
}

main "$@"
