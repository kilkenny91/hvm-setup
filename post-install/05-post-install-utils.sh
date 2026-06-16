#!/bin/bash
# =============================================================================
# Script 5: Zusätzliche sinnvolle Konfigurationen
# - VM Traffic Bridge/VLAN Vorbereitung
# - SSH Hardening Basics
# - NTP/Chrony
# - Firewall (ufw) Grundkonfiguration
# - Logging & Monitoring Vorbereitung
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"

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
    fi
}

configure_chrony() {
    local ntp_server="${1:-pool.ntp.org}"

    apt-get install -y -qq chrony 2>/dev/null || true

    if [[ -f /etc/chrony/chrony.conf ]]; then
        if ! grep -q "^server ${ntp_server}" /etc/chrony/chrony.conf; then
            sed -i "s/^pool.*/server ${ntp_server} iburst/" /etc/chrony/chrony.conf 2>/dev/null || \
                echo "server ${ntp_server} iburst" >> /etc/chrony/chrony.conf
        fi
    fi

    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true
    log_info "NTP/Chrony konfiguriert (Server: ${ntp_server})"
}

configure_vm_traffic_bridge() {
    local vm_ifaces="$1"
    local bridge_name="${2:-br-vm}"

    [[ -z "$vm_ifaces" ]] && return 0

    local netplan_file="/etc/netplan/99-hvm-vm-traffic.yaml"
    local members="" ethernets=""

    IFS=',' read -ra IFACES <<< "$vm_ifaces"
    for iface in "${IFACES[@]}"; do
        iface=$(echo "$iface" | xargs)
        [[ -z "$iface" ]] && continue
        ethernets+="    ${iface}:
      dhcp4: false
"
        [[ -n "$members" ]] && members+=", "
        members+="\"${iface}\""
    done

    [[ -z "$members" ]] && return 0

    cat > "$netplan_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
${ethernets}
  bridges:
    ${bridge_name}:
      interfaces: [${members}]
      dhcp4: false
      parameters:
        stp: false
        forward-delay: 0
EOF

    netplan generate
    netplan apply
    log_info "VM-Traffic Bridge '${bridge_name}' erstellt (${vm_ifaces})"
}

configure_firewall() {
    local mgmt_ip="$1"

    apt-get install -y -qq ufw 2>/dev/null || return 0

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # SSH von Management-Netz
    ufw allow from "${mgmt_ip%.*}.0/24" to any port 22 proto tcp comment 'SSH Management'

    # Libvirt/VNC
    ufw allow in on virbr0

    ufw --force enable
    log_info "UFW Firewall konfiguriert"
}

create_helper_scripts() {
    cat > /root/show-hvm-status.sh << 'EOF'
#!/bin/bash
echo "=== HPE HVM Host Status ==="
echo "Hostname: $(hostname -f)"
echo ""
echo "--- Netzwerk ---"
ip -br addr
echo ""
echo "--- Bonds ---"
cat /proc/net/bonding/bond* 2>/dev/null | head -30 || echo "Keine Bonds"
echo ""
echo "--- iSCSI ---"
iscsiadm -m session 2>/dev/null || echo "Keine iSCSI Sessions"
echo ""
echo "--- Multipath ---"
multipath -ll 2>/dev/null | head -20 || echo "Keine Multipath Devices"
echo ""
echo "--- VMs ---"
virsh list --all 2>/dev/null || echo "Libvirt nicht verfügbar"
EOF
    chmod +x /root/show-hvm-status.sh
    log_info "Hilfs-Skript erstellt: /root/show-hvm-status.sh"
}

save_vm_traffic_config() {
    local vm_ifaces="$1"
    cat > /root/config/vm-traffic-interfaces.env << EOF
# VM Traffic Interfaces (Referenz)
VM_TRAFFIC_INTERFACES=${vm_ifaces}
# Bridge für VMs: br-vm
EOF
    log_info "VM-Traffic Referenz gespeichert: /root/config/vm-traffic-interfaces.env"
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 5: Zusätzliche Konfigurationen"
    echo "=========================================="

    load_params

    echo ""
    echo "Welche Optionen sollen konfiguriert werden?"
    echo ""

    # NTP
    read -rp "NTP/Chrony konfigurieren? (y/n) [y]: " do_ntp
    do_ntp="${do_ntp:-y}"
    if [[ "$do_ntp" =~ ^[Yy]$ ]]; then
        prompt NTP_SERVER "NTP Server" "${GATEWAY:-pool.ntp.org}"
        configure_chrony "$NTP_SERVER"
    fi

    # VM Traffic Bridge
    read -rp "VM-Traffic Bridge erstellen? (y/n) [y]: " do_bridge
    do_bridge="${do_bridge:-y}"
    if [[ "$do_bridge" =~ ^[Yy]$ ]]; then
        prompt VM_TRAFFIC_INTERFACES "VM-Traffic Interfaces" "${VM_TRAFFIC_INTERFACES:-}"
        if [[ -n "$VM_TRAFFIC_INTERFACES" ]]; then
            prompt BRIDGE_NAME "Bridge Name" "br-vm"
            configure_vm_traffic_bridge "$VM_TRAFFIC_INTERFACES" "$BRIDGE_NAME"
            save_vm_traffic_config "$VM_TRAFFIC_INTERFACES"
        fi
    fi

    # Firewall
    read -rp "UFW Firewall aktivieren? (y/n) [n]: " do_fw
    do_fw="${do_fw:-n}"
    if [[ "$do_fw" =~ ^[Yy]$ ]]; then
        configure_firewall "${IP_ADDRESS:-192.168.0.1}"
    fi

    create_helper_scripts

    echo ""
    log_info "Zusätzliche Konfigurationen abgeschlossen."
    echo ""
    echo "Status anzeigen: /root/show-hvm-status.sh"
}

main "$@"
