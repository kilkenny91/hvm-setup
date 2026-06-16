#!/bin/bash
# =============================================================================
# Script 0: Management-Netzwerk konfigurieren (Bond + VLAN)
# Wird aus install-params.env gelesen; kann auch interaktiv abgefragt werden
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
NETPLAN_FILE="/etc/netplan/99-hvm-mgmt.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

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
    else
        log_warn "Keine install-params.env gefunden, interaktive Abfrage..."
    fi
}

collect_params() {
    prompt HOSTNAME "Hostname" "${HOSTNAME:-}"
    prompt IP_ADDRESS "IP-Adresse (Management)" "${IP_ADDRESS:-}"
    prompt NETMASK "Subnetzmaske" "${NETMASK:-255.255.255.0}"
    prompt GATEWAY "Gateway" "${GATEWAY:-}"
    prompt VLAN_ID "VLAN-ID" "${VLAN_ID:-1}"
    prompt MGMT_INTERFACES "Management-Interfaces (kommagetrennt)" "${MGMT_INTERFACES:-eno1,eno2}"
    prompt MGMT_BOND_MODE "Bond-Modus (802.3ad/active-backup)" "${MGMT_BOND_MODE:-802.3ad}"
}

netmask_to_cidr() {
    local mask="$1" cidr=0
    local i1 i2 i3 i4
    IFS=. read -r i1 i2 i3 i4 <<< "$mask"
    for octet in $i1 $i2 $i3 $i4; do
        while [[ $octet -gt 0 ]]; do
            cidr=$((cidr + octet % 2))
            octet=$((octet / 2))
        done
    done
    echo "$cidr"
}

validate_interfaces() {
    local missing=()
    IFS=',' read -ra IFACES <<< "$MGMT_INTERFACES"
    for iface in "${IFACES[@]}"; do
        iface=$(echo "$iface" | xargs)
        if ! ip link show "$iface" &>/dev/null; then
            missing+=("$iface")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Folgende Interfaces nicht gefunden: ${missing[*]}"
        read -rp "Trotzdem fortfahren? (y/n): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
}

generate_netplan() {
    local cidr bond_ifaces="" ethernets=""
    cidr=$(netmask_to_cidr "$NETMASK")

    IFS=',' read -ra IFACES <<< "$MGMT_INTERFACES"
    for iface in "${IFACES[@]}"; do
        iface=$(echo "$iface" | xargs)
        ethernets+="      ${iface}:
        dhcp4: false
"
        [[ -n "$bond_ifaces" ]] && bond_ifaces+=", "
        bond_ifaces+="\"${iface}\""
    done

    local bond_params=""
    if [[ "$MGMT_BOND_MODE" == "802.3ad" ]]; then
        bond_params="          mode: 802.3ad
          lacp-rate: fast
          mii-monitor-interval: 100
          transmit-hash-policy: layer3+4"
    else
        bond_params="          mode: active-backup
          mii-monitor-interval: 100"
    fi

    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
${ethernets}
  bonds:
    bond0:
      interfaces: [${bond_ifaces}]
      parameters:
${bond_params}
  vlans:
    bond0.${VLAN_ID}:
      id: ${VLAN_ID}
      link: bond0
      addresses:
        - ${IP_ADDRESS}/${cidr}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${GATEWAY}]
EOF

    log_info "Netplan-Konfiguration erstellt: $NETPLAN_FILE"
}

apply_config() {
    hostnamectl set-hostname "${HOSTNAME}"
    log_info "Hostname gesetzt: ${HOSTNAME}"

    netplan generate
    netplan apply
    log_info "Netplan angewendet"

    echo ""
    echo "Aktuelle Bond/VLAN-Konfiguration:"
    ip -br addr show bond0 2>/dev/null || true
    ip -br addr show "bond0.${VLAN_ID}" 2>/dev/null || true
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 0: Management-Netzwerk (Bond+VLAN)"
    echo "=========================================="
    echo ""

    load_params
    collect_params
    validate_interfaces

    echo ""
    echo "Konfiguration:"
    echo "  Bond: bond0 (${MGMT_INTERFACES})"
    echo "  VLAN: bond0.${VLAN_ID}"
    echo "  IP:   ${IP_ADDRESS}/${NETMASK}"
    echo "  GW:   ${GATEWAY}"
    echo ""
    read -rp "Konfiguration anwenden? (y/n) [y]: " confirm
    confirm="${confirm:-y}"
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Abgebrochen."; exit 0; }

    generate_netplan
    apply_config
    log_info "Management-Netzwerk konfiguriert."
}

main "$@"
