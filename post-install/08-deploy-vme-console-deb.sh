#!/bin/bash
# =============================================================================
# Script 8: hpe-vm_*.deb auf allen Cluster-Hosts installieren
#
# - Installiert lokal (dieser Host)
# - Verteilt .deb per scp und installiert per ssh auf Remote-Hosts
# - Hosts aus Ansible-Inventory oder interaktive Eingabe
#
# Voraussetzung: Script 4 hat ISO extrahiert ODER .deb liegt unter /root/installers/
# Empfohlen nach Script 7 (SSH-Keys) für passwortlosen Zugriff
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
VME_CONFIG="/root/config/vme-install.env"
INSTALLER_DIR="/root/installers"
EXTRACT_DIR="${INSTALLER_DIR}/vme-extracted"
MOUNT_POINT="/mnt/hpe-vme-iso"
INVENTORY_FILE="/root/ansible/inventory/hosts"
REMOTE_INSTALL_DIR="/root/installers"

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

prompt_secret() {
    local var_name="$1" prompt_text="$2"
    read -rsp "${prompt_text}: " input
    echo ""
    printf -v "$var_name" '%s' "$input"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$PARAMS_FILE"
    fi
    if [[ -f "$VME_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$VME_CONFIG"
    fi
}

find_deb_package() {
    # Bereits aus Script 4 bekannt
    if [[ -n "${DEB_PACKAGE:-}" && -f "$DEB_PACKAGE" ]]; then
        echo "$DEB_PACKAGE"
        return 0
    fi

    local found
    found=$(find "$EXTRACT_DIR" "$INSTALLER_DIR" -maxdepth 2 -type f -name "hpe-vm*.deb" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi

    # Aus ISO extrahieren
    local iso_file
    iso_file=$(find "$INSTALLER_DIR" -maxdepth 1 -type f -iname "*.iso" 2>/dev/null | head -1)
    if [[ -z "$iso_file" ]]; then
        return 1
    fi

    log_info "Extrahiere .deb aus ISO: ${iso_file}"
    mkdir -p "$EXTRACT_DIR" "$MOUNT_POINT"
    mount -o loop,ro "$iso_file" "$MOUNT_POINT"
    found=$(find "$MOUNT_POINT" -maxdepth 2 -type f -name "hpe-vm*.deb" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        cp "$found" "${EXTRACT_DIR}/"
        umount "$MOUNT_POINT" 2>/dev/null || true
        echo "${EXTRACT_DIR}/$(basename "$found")"
        return 0
    fi

    umount "$MOUNT_POINT" 2>/dev/null || true
    return 1
}

is_installed_locally() {
    dpkg -l 2>/dev/null | grep -qE '^ii\s+hpe-vm' || command -v hpe-vm >/dev/null 2>&1
}

install_deb_local() {
    local deb="$1"

    if is_installed_locally; then
        log_info "Lokal bereits installiert (hpe-vm vorhanden)."
        read -rp "Trotzdem neu installieren? (y/n) [n]: " reinstall
        reinstall="${reinstall:-n}"
        [[ "$reinstall" =~ ^[Yy]$ ]] || return 0
    fi

    log_info "Installiere lokal: ${deb}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -f "$deb"

    if command -v hpe-vm >/dev/null 2>&1; then
        log_info "Lokal OK: $(hpe-vm --version 2>/dev/null || echo 'hpe-vm verfügbar')"
    else
        log_warn "Installation abgeschlossen, aber 'hpe-vm' nicht im PATH."
    fi
}

parse_inventory_hosts() {
    local inv_file="$1"
    [[ -f "$inv_file" ]] || return 1

    awk '
        /^\[/ { in_group=1; next }
        /^#/ || /^$/ { next }
        /ansible_connection=local/ { next }
        in_group && NF {
            alias=$1
            ip=""; user="root"; port="22"
            for (i=2; i<=NF; i++) {
                if ($i ~ /^ansible_host=/) { split($i,a,"="); ip=a[2] }
                if ($i ~ /^ansible_user=/) { split($i,a,"="); user=a[2] }
                if ($i ~ /^ansible_port=/) { split($i,a,"="); port=a[2] }
            }
            if (ip != "") print alias "|" ip "|" user "|" port
        }
    ' "$inv_file"
}

collect_hosts_interactive() {
    local hosts=()
    echo ""
    echo "Remote-Hosts eingeben (leerer Hostname = fertig):"
    while true; do
        local alias ip user port
        prompt alias "  Hostname/Alias" ""
        [[ -z "$alias" ]] && break
        prompt ip "  IP-Adresse" ""
        prompt user "  SSH-Benutzer" "root"
        prompt port "  SSH-Port" "22"
        hosts+=("${alias}|${ip}|${user}|${port}")
    done
    printf '%s\n' "${hosts[@]}"
}

install_deb_remote() {
    local alias="$1" ip="$2" user="$3" port="$4"
    local deb="$5"
    local deb_name
    deb_name=$(basename "$deb")

    log_info "Remote: ${user}@${ip} (${alias})"

    local ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$port")
    local scp_opts=(-o StrictHostKeyChecking=accept-new -P "$port")

    if [[ -n "${SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${ssh_opts[@]}" "${user}@${ip}" "mkdir -p ${REMOTE_INSTALL_DIR}"
        SSHPASS="$SSH_PASSWORD" sshpass -e scp "${scp_opts[@]}" "$deb" "${user}@${ip}:${REMOTE_INSTALL_DIR}/${deb_name}"
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${ssh_opts[@]}" "${user}@${ip}" \
            "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -f ${REMOTE_INSTALL_DIR}/${deb_name}"
    else
        ssh "${ssh_opts[@]}" "${user}@${ip}" "mkdir -p ${REMOTE_INSTALL_DIR}"
        scp "${scp_opts[@]}" "$deb" "${user}@${ip}:${REMOTE_INSTALL_DIR}/${deb_name}"
        ssh "${ssh_opts[@]}" "${user}@${ip}" \
            "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -f ${REMOTE_INSTALL_DIR}/${deb_name}"
    fi

    if ssh "${ssh_opts[@]}" "${user}@${ip}" "command -v hpe-vm" &>/dev/null; then
        log_info "  OK: hpe-vm auf ${alias} installiert."
        return 0
    else
        log_warn "  hpe-vm auf ${alias} nicht gefunden – manuell prüfen."
        return 1
    fi
}

install_via_ansible() {
    local deb="$1"
    local playbook="/root/ansible/playbooks/install-vme-console.yml"

    if ! command -v ansible-playbook >/dev/null 2>&1 || [[ ! -f "$INVENTORY_FILE" ]]; then
        return 1
    fi

    cat > "$playbook" << 'EOF'
---
- name: Install HPE VM Essentials Console (.deb)
  hosts: all
  gather_facts: true
  become: true

  tasks:
    - name: Skip localhost (bereits lokal installiert)
      ansible.builtin.meta: end_host
      when: ansible_connection == 'local'

    - name: Install-Verzeichnis anlegen
      ansible.builtin.file:
        path: /root/installers
        state: directory
        mode: "0700"

    - name: hpe-vm .deb kopieren
      ansible.builtin.copy:
        src: "{{ vme_deb_path }}"
        dest: "/root/installers/{{ vme_deb_name }}"
        mode: "0644"

    - name: Paket installieren
      ansible.builtin.apt:
        deb: "/root/installers/{{ vme_deb_name }}"
        state: present
        update_cache: true

    - name: hpe-vm verfügbar?
      ansible.builtin.command: hpe-vm --version
      register: hpe_vm_version
      changed_when: false
      failed_when: false

    - name: Ergebnis
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }}: {{ hpe_vm_version.stdout | default('hpe-vm installiert') }}"
EOF

    log_info "Installation via Ansible-Playbook..."
    cd /root/ansible
    ansible-playbook "$playbook" \
        -e "vme_deb_path=${deb}" \
        -e "vme_deb_name=$(basename "$deb")" \
        --limit '!local'
    return 0
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 8: VM Essentials .deb deployen"
    echo "=========================================="

    load_params

    local deb
    deb=$(find_deb_package) || {
        log_error "Kein hpe-vm*.deb gefunden."
        echo ""
        echo "Zuerst Script 4 ausführen (ISO extrahieren) oder .deb nach ${INSTALLER_DIR}/ legen."
        exit 1
    }

    log_info "Debian-Paket: ${deb}"

    echo ""
    read -rp "Lokal auf diesem Host installieren? (y/n) [y]: " do_local
    do_local="${do_local:-y}"
    [[ "$do_local" =~ ^[Yy]$ ]] && install_deb_local "$deb"

    echo ""
    read -rp "Auf Remote-Hosts installieren? (y/n) [y]: " do_remote
    do_remote="${do_remote:-y}"
    [[ "$do_remote" =~ ^[Yy]$ ]] || { log_info "Fertig."; exit 0; }

    local host_lines=()
    if [[ -f "$INVENTORY_FILE" ]]; then
        log_info "Hosts aus Ansible-Inventory: ${INVENTORY_FILE}"
        mapfile -t host_lines < <(parse_inventory_hosts "$INVENTORY_FILE")
    fi

    if [[ ${#host_lines[@]} -eq 0 ]]; then
        log_warn "Keine Remote-Hosts im Inventory."
        mapfile -t host_lines < <(collect_hosts_interactive)
    fi

    if [[ ${#host_lines[@]} -eq 0 ]]; then
        log_info "Keine Remote-Hosts – nur lokale Installation."
        exit 0
    fi

    echo ""
    echo "Ziel-Hosts:"
    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        echo "  - ${alias}: ${user}@${ip}:${port}"
    done
    echo ""

    read -rp "Ansible-Playbook verwenden (falls SSH-Keys eingerichtet)? (y/n) [y]: " use_ansible
    use_ansible="${use_ansible:-y}"
    if [[ "$use_ansible" =~ ^[Yy]$ ]] && install_via_ansible "$deb"; then
        log_info "Remote-Installation via Ansible abgeschlossen."
        exit 0
    fi

    read -rp "SSH-Passwort für sshpass verwenden? (y/n) [n]: " use_pw
    use_pw="${use_pw:-n}"
    SSH_PASSWORD=""
    if [[ "$use_pw" =~ ^[Yy]$ ]]; then
        prompt_secret SSH_PASSWORD "SSH-Passwort (alle Hosts)"
    fi

    local failed=0
    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        [[ -z "$ip" ]] && continue
        install_deb_remote "$alias" "$ip" "$user" "$port" "$deb" || failed=$((failed + 1))
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        log_info "hpe-vm Console auf allen Hosts installiert."
        echo ""
        echo "Nächster Schritt auf jedem Host: hpe-vm  (Netzwerk konfigurieren)"
    else
        log_warn "${failed} Host(s) fehlgeschlagen."
    fi
}

main "$@"
