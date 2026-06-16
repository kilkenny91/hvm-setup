#!/bin/bash
# =============================================================================
# Script 9: Ops-VM mit Docker (Syslog, Grafana, Prometheus)
#
# - Erstellt KVM-VM im gleichen Management-Netz wie der Host (macvtap)
# - Installiert Docker Compose Stack: syslog-ng, Prometheus, Grafana, Alertmanager
# - Konfiguriert Log-Forwarding (rsyslog) auf Host(s)
# - Optional: node_exporter auf HVM-Hosts
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_VM_DIR="${SCRIPT_DIR}/ops-vm"
PARAMS_FILE="/root/install-params.env"
CONFIG_FILE="/root/config/ops-vm.env"
INVENTORY_FILE="/root/ansible/inventory/hosts"

VM_NAME="${VM_NAME:-ops-monitor}"
VM_STORAGE="/var/lib/libvirt/images"
CLOUD_IMAGE="${VM_STORAGE}/ubuntu-24.04-cloudimg-amd64.img"
VM_DISK="${VM_STORAGE}/${VM_NAME}.qcow2"
CICD_ISO="${VM_STORAGE}/${VM_NAME}-cidata.iso"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

suggest_higher_ip() {
    local base_ip="$1" offset="${2:-10}"
    local a b c d
    IFS=. read -r a b c d <<< "$base_ip"
    d=$((d + offset))
    [[ $d -gt 254 ]] && d=254
    echo "${a}.${b}.${c}.${d}"
}

get_mgmt_interface() {
    if [[ -n "${VLAN_ID:-}" ]]; then
        echo "bond0.${VLAN_ID}"
    else
        ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
    fi
}

install_prerequisites() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
        cloud-image-utils wget curl genisoimage \
        prometheus-node-exporter 2>/dev/null || \
        apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
            virtinst cloud-image-utils wget curl genisoimage prometheus-node-exporter

    systemctl enable --now libvirtd 2>/dev/null || true
    systemctl enable --now prometheus-node-exporter 2>/dev/null || true
}

download_cloud_image() {
    if [[ -f "$CLOUD_IMAGE" ]]; then
        log_info "Cloud-Image vorhanden: ${CLOUD_IMAGE}"
        return 0
    fi

    log_info "Lade Ubuntu 24.04 Cloud-Image..."
    mkdir -p "$VM_STORAGE"
    wget -q --show-progress -O "$CLOUD_IMAGE" \
        "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

prepare_ops_vm_files() {
    local staging="/root/ops-vm-stack"
    rm -rf "$staging"
    mkdir -p "$staging"

    if [[ -d "$OPS_VM_DIR" ]]; then
        cp -a "$OPS_VM_DIR/." "$staging/"
    else
        log_error "Ops-VM Templates nicht gefunden: ${OPS_VM_DIR}"
        exit 1
    fi

    local targets=()
    targets+=("\"${IP_ADDRESS:-$(hostname -I | awk '{print $1}')}:9100\"")
    if [[ -f "$INVENTORY_FILE" ]]; then
        while IFS='|' read -r _ ip _ _; do
            [[ -n "$ip" ]] && targets+=("\"${ip}:9100\"")
        done < <(parse_inventory_hosts "$INVENTORY_FILE")
    fi

    cat > "$staging/prometheus/prometheus.yml" << EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090

  - job_name: node_exporter
    static_configs:
      - targets:
$(printf '          - %s\n' "${targets[@]}")
        labels:
          group: hvm-hosts
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+):.*'
        target_label: host
        replacement: '\$1'
EOF

    cat > "$staging/.env" << EOF
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
OPS_VM_IP=${OPS_VM_IP}
EOF

    echo "$staging"
}

generate_cloud_init() {
    local ci_dir="/tmp/ops-vm-cloud-init-$$"
    mkdir -p "$ci_dir"

    local ssh_pubkey=""
    if [[ -f /root/.ssh/id_ed25519.pub ]]; then
        ssh_pubkey=$(cat /root/.ssh/id_ed25519.pub)
    elif [[ -f /root/.ssh/id_rsa.pub ]]; then
        ssh_pubkey=$(cat /root/.ssh/id_rsa.pub)
    fi

    cat > "${ci_dir}/meta-data" << EOF
instance-id: ${VM_NAME}-001
local-hostname: ${VM_HOSTNAME:-ops-monitor}
EOF

    cat > "${ci_dir}/network-config" << EOF
version: 2
ethernets:
  enp1s0:
    match:
      name: en*
    dhcp4: false
    addresses:
      - ${OPS_VM_IP}/${OPS_VM_CIDR}
    routes:
      - to: default
        via: ${OPS_VM_GATEWAY}
    nameservers:
      addresses: [${OPS_VM_DNS}]
EOF

    cat > "${ci_dir}/user-data" << EOF
#cloud-config
hostname: ${VM_HOSTNAME:-ops-monitor}
manage_etc_hosts: true
package_update: true
packages:
  - docker.io
  - docker-compose-v2
users:
  - name: opsadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: docker
$( [[ -n "$ssh_pubkey" ]] && echo "    ssh_authorized_keys:" && echo "      - ${ssh_pubkey}" )
runcmd:
  - systemctl enable --now docker
EOF

    cloud-localds "$CICD_ISO" "${ci_dir}/user-data" "${ci_dir}/meta-data" "${ci_dir}/network-config"
    rm -rf "$ci_dir"
    log_info "Cloud-Init ISO erstellt: ${CICD_ISO}"
}

deploy_stack_to_vm() {
    local staging="$1"
    local max=30 i=0

    log_info "Warte auf SSH (${OPS_VM_IP})..."
    while [[ $i -lt $max ]]; do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            "opsadmin@${OPS_VM_IP}" "echo ok" &>/dev/null; then
            break
        fi
        sleep 10
        i=$((i + 1))
    done

    if [[ $i -ge $max ]]; then
        log_error "SSH zur Ops-VM nicht erreichbar. Stack manuell deployen:"
        echo "  scp -r ${staging} opsadmin@${OPS_VM_IP}:/opt/ops"
        return 1
    fi

    ssh -o StrictHostKeyChecking=accept-new "opsadmin@${OPS_VM_IP}" \
        "sudo mkdir -p /opt/ops && sudo chown opsadmin:opsadmin /opt/ops"
    scp -o StrictHostKeyChecking=accept-new -r "${staging}/." "opsadmin@${OPS_VM_IP}:/opt/ops/"
    ssh -o StrictHostKeyChecking=accept-new "opsadmin@${OPS_VM_IP}" \
        "cd /opt/ops && docker compose --env-file .env up -d"

    log_info "Docker Compose Stack gestartet."

    # Prometheus-Konfiguration neu laden (node_exporter Targets)
    ssh -o StrictHostKeyChecking=accept-new "opsadmin@${OPS_VM_IP}" \
        "docker exec ops-prometheus wget -qO- --post-data='' http://localhost:9090/-/reload 2>/dev/null" \
        && log_info "Prometheus-Konfiguration neu geladen." || true
}

create_vm() {
    local mgmt_iface="$1"

    if virsh dominfo "$VM_NAME" &>/dev/null; then
        log_warn "VM '${VM_NAME}' existiert bereits."
        read -rp "Bestehende VM ersetzen? (y/n) [n]: " replace
        [[ "$replace" =~ ^[Yy]$ ]] || return 0
        virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || \
            virsh undefine "$VM_NAME" 2>/dev/null || true
        rm -f "$VM_DISK" "$CICD_ISO"
    fi

    download_cloud_image

    if [[ ! -f "$VM_DISK" ]]; then
        qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMAGE" "$VM_DISK" 40G
    fi

    log_info "Erstelle VM '${VM_NAME}' an Interface ${mgmt_iface}..."

    virt-install \
        --name "$VM_NAME" \
        --memory "${VM_MEMORY:-4096}" \
        --vcpus "${VM_VCPUS:-2}" \
        --disk "path=${VM_DISK},format=qcow2,bus=virtio" \
        --disk "path=${CICD_ISO},device=cdrom" \
        --os-variant ubuntu24.04 \
        --network "type=direct,source=${mgmt_iface},source_mode=bridge,model=virtio" \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole

    log_info "VM gestartet. Warte auf Erreichbarkeit ${OPS_VM_IP}..."
}

wait_for_vm() {
    local ip="$1" max=60 i=0
    while [[ $i -lt $max ]]; do
        if ping -c1 -W2 "$ip" &>/dev/null; then
            log_info "VM erreichbar: ${ip}"
            sleep 15
            return 0
        fi
        sleep 5
        i=$((i + 1))
    done
    log_warn "VM antwortet nicht auf Ping – ggf. manuell prüfen."
    return 1
}

configure_rsyslog_forward_local() {
    local syslog_ip="$1"
    local conf="/etc/rsyslog.d/49-ops-forward.conf"

    cat > "$conf" << EOF
# Zentraler Syslog-Server (Ops-VM) – generiert von 09-deploy-ops-vm.sh
# TCP-Forwarding (zuverlässiger als UDP)
*.* @@${syslog_ip}:514
EOF

    systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null || true
    log_info "Lokales rsyslog-Forwarding → ${syslog_ip}:514"
}

run_ansible_playbook() {
    local playbook="$1"
    shift
    local extra_args=("$@")

    if ! command -v ansible-playbook >/dev/null 2>&1; then
        return 1
    fi
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        return 1
    fi
    if [[ ! -f "$playbook" ]]; then
        log_error "Playbook nicht gefunden: ${playbook}"
        return 1
    fi

    mkdir -p /root/ansible/playbooks
    cp -f "${OPS_VM_DIR}/ansible/"*.yml /root/ansible/playbooks/ 2>/dev/null || true

    cd /root/ansible
    ansible-playbook "$playbook" -i "$INVENTORY_FILE" "${extra_args[@]}"
}

deploy_rsyslog_via_ansible() {
    local syslog_ip="$1"
    local playbook="${OPS_VM_DIR}/ansible/configure-rsyslog-forward.yml"
    [[ -f "$playbook" ]] || playbook="/root/post-install/ops-vm/ansible/configure-rsyslog-forward.yml"

    log_info "rsyslog-Forwarding via Ansible auf alle Inventory-Hosts..."
    run_ansible_playbook "$playbook" -e "ops_syslog_server_ip=${syslog_ip}"
}

deploy_node_exporter_via_ansible() {
    local playbook="${OPS_VM_DIR}/ansible/install-node-exporter.yml"
    [[ -f "$playbook" ]] || playbook="/root/post-install/ops-vm/ansible/install-node-exporter.yml"

    log_info "node_exporter via Ansible auf alle Inventory-Hosts..."
    run_ansible_playbook "$playbook"
}

configure_rsyslog_all_hosts() {
    local syslog_ip="$1"

    echo ""
    read -rp "rsyslog-Forwarding auf allen Hosts konfigurieren? (y/n) [y]: " do_rsyslog
    do_rsyslog="${do_rsyslog:-y}"
    [[ "$do_rsyslog" =~ ^[Yy]$ ]] || return 0

    if [[ -f "$INVENTORY_FILE" ]]; then
        read -rp "Via Ansible ausrollen (empfohlen)? (y/n) [y]: " use_ansible
        use_ansible="${use_ansible:-y}"
        if [[ "$use_ansible" =~ ^[Yy]$ ]] && deploy_rsyslog_via_ansible "$syslog_ip"; then
            log_info "rsyslog-Forwarding via Ansible abgeschlossen."
            return 0
        fi
        log_warn "Ansible fehlgeschlagen oder übersprungen – Fallback per SSH."
    fi

    configure_rsyslog_forward_local "$syslog_ip"
    configure_rsyslog_forward_remote "$syslog_ip"
}

install_node_exporter_all_hosts() {
    echo ""
    read -rp "node_exporter auf allen Hosts installieren? (y/n) [y]: " do_ne
    do_ne="${do_ne:-y}"
    [[ "$do_ne" =~ ^[Yy]$ ]] || return 0

    if [[ -f "$INVENTORY_FILE" ]]; then
        read -rp "Via Ansible ausrollen (empfohlen)? (y/n) [y]: " use_ansible
        use_ansible="${use_ansible:-y}"
        if [[ "$use_ansible" =~ ^[Yy]$ ]] && deploy_node_exporter_via_ansible; then
            log_info "node_exporter via Ansible abgeschlossen."
            return 0
        fi
        log_warn "Ansible fehlgeschlagen oder übersprungen – Fallback per SSH."
    else
        log_info "Lokalen node_exporter installieren..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq prometheus-node-exporter 2>/dev/null || true
        systemctl enable --now prometheus-node-exporter 2>/dev/null || true
    fi

    install_node_exporter_remote
}

parse_inventory_hosts() {
    awk '
        /^\[/ { in_group=1; next }
        /^#/ || /^$/ { next }
        /ansible_connection=local/ { next }
        in_group && NF {
            ip=""; user="root"; port="22"
            for (i=2; i<=NF; i++) {
                if ($i ~ /^ansible_host=/) { split($i,a,"="); ip=a[2] }
                if ($i ~ /^ansible_user=/) { split($i,a,"="); user=a[2] }
                if ($i ~ /^ansible_port=/) { split($i,a,"="); port=a[2] }
            }
            if (ip != "") print $1 "|" ip "|" user "|" port
        }
    ' "$1"
}

configure_rsyslog_forward_remote() {
    local syslog_ip="$1"
    local conf_content="# Ops-VM Syslog Forwarding
*.* @@${syslog_ip}:514"

    local host_lines=()
    if [[ -f "$INVENTORY_FILE" ]]; then
        mapfile -t host_lines < <(parse_inventory_hosts "$INVENTORY_FILE")
    fi

    [[ ${#host_lines[@]} -eq 0 ]] && return 0

    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        log_info "Konfiguriere rsyslog auf ${alias} (${ip})..."
        ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${ip}" bash -s << REMOTE
echo '${conf_content}' > /etc/rsyslog.d/49-ops-forward.conf
systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null || true
REMOTE
    done
}

install_node_exporter_remote() {
    local host_lines=()
    [[ -f "$INVENTORY_FILE" ]] && mapfile -t host_lines < <(parse_inventory_hosts "$INVENTORY_FILE")

    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        log_info "node_exporter auf ${alias}..."
        ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${ip}" \
            "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq prometheus-node-exporter && systemctl enable --now prometheus-node-exporter" \
            2>/dev/null || log_warn "  Fehlgeschlagen: ${alias}"
    done
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
OPS_VM_NAME=${VM_NAME}
OPS_VM_IP=${OPS_VM_IP}
OPS_VM_GATEWAY=${OPS_VM_GATEWAY}
OPS_VM_CIDR=${OPS_VM_CIDR}
OPS_VM_DNS=${OPS_VM_DNS}
OPS_VM_HOSTNAME=${VM_HOSTNAME:-ops-monitor}
SYSLOG_SERVER_IP=${OPS_VM_IP}
GRAFANA_URL=http://${OPS_VM_IP}:3000
PROMETHEUS_URL=http://${OPS_VM_IP}:9090
MGMT_INTERFACE=${MGMT_INTERFACE:-}
EOF
    chmod 600 "$CONFIG_FILE"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "  Ops-VM bereitgestellt"
    echo "=========================================="
    echo ""
    echo "  VM Name:     ${VM_NAME}"
    echo "  VM IP:       ${OPS_VM_IP}"
    echo "  Syslog:      ${OPS_VM_IP}:514 (TCP/UDP)"
    echo "  Grafana:     http://${OPS_VM_IP}:3000  (admin / ${GRAFANA_ADMIN_PASSWORD})"
    echo "  Prometheus:  http://${OPS_VM_IP}:9090"
    echo "  Loki:        http://${OPS_VM_IP}:3100"
    echo ""
    echo "  Log-Analyse in Grafana:"
    echo "    Dashboard: Ops → HVM Syslog Analyse"
    echo "    Explore:   Data source Loki → {job=\"syslog\"}"
    echo ""
    echo "  Metriken in Grafana:"
    echo "    Dashboard: Ops → HVM Host Metriken"
    echo "    Prometheus Targets: http://${OPS_VM_IP}:9090/targets"
    echo "    (node_exporter auf Hosts via Script 9 / Ansible)"
    echo ""
    echo "  Log-Pipeline: Hosts (rsyslog) → syslog-ng → Promtail → Loki → Grafana"
    echo ""
    echo "  Syslog-Speicher (persistent in VM):"
    echo "    Docker Volume ops-syslog-data → /var/log/syslog-ng/remote/"
    echo "    Docker Volume ops-loki-data   → Loki Index + Chunks (30 Tage Retention)"
    echo ""
    echo "  Logs in VM prüfen:"
    echo "    ssh opsadmin@${OPS_VM_IP}"
    echo "    sudo docker exec ops-syslog-ng ls -la /var/log/syslog-ng/remote/"
    echo ""
    echo "  Konfiguration: ${CONFIG_FILE}"
}

collect_inputs() {
    local host_ip="${IP_ADDRESS:-$(hostname -I | awk '{print $1}')}"
    local default_vm_ip
    default_vm_ip=$(suggest_higher_ip "$host_ip" 10)

    echo ""
    prompt VM_HOSTNAME "VM Hostname" "ops-monitor"
    prompt OPS_VM_IP "VM IP-Adresse (Management-Netz)" "$default_vm_ip"
    prompt OPS_VM_GATEWAY "Gateway" "${GATEWAY:-}"
    prompt OPS_VM_CIDR "CIDR (Subnetz)" "${CIDR:-24}"
    prompt OPS_VM_DNS "DNS" "${DNS_SERVERS:-${GATEWAY:-8.8.8.8}}"

    MGMT_INTERFACE=$(get_mgmt_interface)
    prompt MGMT_INTERFACE "Libvirt/macvtap Quell-Interface" "$MGMT_INTERFACE"

    prompt VM_MEMORY "VM RAM (MB)" "4096"
    prompt VM_VCPUS "VM vCPUs" "2"
    prompt GRAFANA_ADMIN_PASSWORD "Grafana Admin-Passwort" "changeme"
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 9: Ops-VM (Syslog + Monitoring)"
    echo "=========================================="

    load_params
    collect_inputs

    echo ""
    echo "Zusammenfassung:"
    echo "  Host IP:        ${IP_ADDRESS:-unbekannt}"
    echo "  Ops-VM IP:      ${OPS_VM_IP}"
    echo "  Netz-Interface: ${MGMT_INTERFACE}"
    echo ""
    read -rp "VM erstellen und Stack deployen? (y/n) [y]: " confirm
    confirm="${confirm:-y}"
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    install_prerequisites

    if [[ ! -f /root/.ssh/id_ed25519.pub && ! -f /root/.ssh/id_rsa.pub ]]; then
        log_warn "Kein SSH Public Key gefunden. Script 7 ausführen oder Key manuell in Cloud-Init hinterlegen."
        read -rp "Trotzdem fortfahren? (y/n) [n]: " noc_key
        noc_key="${noc_key:-n}"
        [[ "$noc_key" =~ ^[Yy]$ ]] || exit 1
    fi

    local staging
    staging=$(prepare_ops_vm_files)
    generate_cloud_init
    create_vm "$MGMT_INTERFACE"
    wait_for_vm "$OPS_VM_IP" || true
    deploy_stack_to_vm "$staging"

    configure_rsyslog_all_hosts "$OPS_VM_IP"
    install_node_exporter_all_hosts

    save_config
    print_summary
    log_info "Ops-VM Deployment abgeschlossen."
}

main "$@"
