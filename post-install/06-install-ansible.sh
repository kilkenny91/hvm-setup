#!/bin/bash
# =============================================================================
# Script 6: Ansible installieren, Inventory aus Benutzereingaben anlegen,
#           Test-Ping-Playbook bereitstellen
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
ANSIBLE_DIR="/root/ansible"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts"
PLAYBOOK_DIR="${ANSIBLE_DIR}/playbooks"

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

install_ansible() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ansible sshpass python3 python3-pip 2>/dev/null || \
        apt-get install -y ansible sshpass python3 python3-pip

    if ! command -v ansible >/dev/null 2>&1; then
        pip3 install --break-system-packages ansible 2>/dev/null || \
            pip3 install ansible
    fi

    log_info "Ansible installiert: $(ansible --version | head -1)"
}

create_ansible_structure() {
    mkdir -p "${ANSIBLE_DIR}/inventory" "${PLAYBOOK_DIR}" "${ANSIBLE_DIR}/group_vars"

    cat > "${ANSIBLE_DIR}/ansible.cfg" << 'EOF'
[defaults]
inventory = /root/ansible/inventory/hosts
remote_user = root
host_key_checking = True
retry_files_enabled = False
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /root/ansible/.cache
fact_caching_timeout = 3600
stdout_callback = yaml
interpreter_python = auto_silent

[privilege_escalation]
become = False

[ssh_connection]
pipelining = True
control_path = /root/ansible/.ssh/ansible-%%r@%%h:%%p
EOF

    mkdir -p "${ANSIBLE_DIR}/.cache" "${ANSIBLE_DIR}/.ssh"
    log_info "Ansible-Verzeichnisstruktur erstellt: ${ANSIBLE_DIR}"
}

collect_inventory_hosts() {
    local groups=()
    local -A group_hosts

    echo ""
    echo "--- Inventory anlegen ---"
    echo "Gruppen und Hosts eingeben. Leerer Gruppenname beendet die Eingabe."
    echo ""

    # Lokaler Host aus install-params
    local local_hostname local_ip
    local_hostname="${HOSTNAME:-$(hostname -s)}"
    local_ip="${IP_ADDRESS:-$(hostname -I | awk '{print $1}')}"

    read -rp "Lokalen Host (${local_hostname}) ins Inventory aufnehmen? (y/n) [y]: " add_local
    add_local="${add_local:-y}"

    if [[ "$add_local" =~ ^[Yy]$ ]]; then
        groups+=("local")
        group_hosts["local"]="${local_hostname} ansible_host=${local_ip} ansible_connection=local"
    fi

    while true; do
        local group_name
        prompt group_name "Gruppenname (Enter = fertig)" ""
        [[ -z "$group_name" ]] && break

        groups+=("$group_name")
        group_hosts["$group_name"]=""

        echo "  Hosts für Gruppe '${group_name}' (leerer Hostname = Gruppe abschließen):"
        while true; do
            local host_name host_ip host_user host_port
            prompt host_name "    Hostname/Alias" ""
            [[ -z "$host_name" ]] && break

            prompt host_ip "    IP-Adresse (ansible_host)" ""
            prompt host_user "    SSH-Benutzer" "root"
            prompt host_port "    SSH-Port" "22"

            local entry="${host_name} ansible_host=${host_ip} ansible_user=${host_user} ansible_port=${host_port}"
            if [[ -n "${group_hosts[$group_name]:-}" ]]; then
                group_hosts["$group_name"]+=$'\n'
            fi
            group_hosts["$group_name"]+="${entry}"
        done

        if [[ -z "${group_hosts[$group_name]:-}" ]]; then
            log_warn "Gruppe '${group_name}' ohne Hosts – wird übersprungen."
            unset "group_hosts[$group_name]"
        fi
    done

    # Inventory-Datei schreiben
    : > "$INVENTORY_FILE"

    for group in "${groups[@]}"; do
        [[ -z "${group_hosts[$group]:-}" ]] && continue
        echo "[${group}]" >> "$INVENTORY_FILE"
        echo "${group_hosts[$group]}" >> "$INVENTORY_FILE"
        echo "" >> "$INVENTORY_FILE"
    done

    # Globale Variablen
    cat >> "$INVENTORY_FILE" << 'EOF'
[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

    log_info "Inventory erstellt: ${INVENTORY_FILE}"
    echo ""
    echo "--- Inventory-Vorschau ---"
    cat "$INVENTORY_FILE"
}

create_ping_playbook() {
    cat > "${PLAYBOOK_DIR}/ping.yml" << 'EOF'
---
# Test-Playbook: Erreichbarkeit aller Inventory-Hosts prüfen
- name: Ping all hosts
  hosts: all
  gather_facts: false

  tasks:
    - name: Ping host (ansible.builtin.ping)
      ansible.builtin.ping:

    - name: Show host info
      ansible.builtin.debug:
        msg: "Host {{ inventory_hostname }} ({{ ansible_host | default('local') }}) ist erreichbar."
EOF

    cat > "${PLAYBOOK_DIR}/ping-local.yml" << 'EOF'
---
# Ping nur lokale/verfügbare Hosts (ohne SSH-Key-Setup)
- name: Ping local host only
  hosts: local
  gather_facts: false

  tasks:
    - name: Ping localhost
      ansible.builtin.ping:
EOF

    log_info "Playbooks erstellt:"
    echo "  ${PLAYBOOK_DIR}/ping.yml"
    echo "  ${PLAYBOOK_DIR}/ping-local.yml"
}

create_group_vars() {
    prompt ANSIBLE_SSH_USER "Standard SSH-Benutzer für alle Hosts" "root"

    cat > "${ANSIBLE_DIR}/group_vars/all.yml" << EOF
---
# Globale Ansible-Variablen
ansible_user: ${ANSIBLE_SSH_USER}
ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'
EOF
}

print_usage() {
    echo ""
    echo "Ansible ist bereit. Nächste Schritte:"
    echo ""
    echo "  1. SSH-Keys einrichten (empfohlen vor erstem Ping):"
    echo "     /root/post-install/07-setup-ssh-for-ansible.sh"
    echo ""
    echo "  2. Inventory prüfen:"
    echo "     ansible-inventory -i ${INVENTORY_FILE} --list"
    echo ""
    echo "  3. Ping-Test (nach SSH-Setup):"
    echo "     cd ${ANSIBLE_DIR} && ansible-playbook playbooks/ping.yml"
    echo ""
    echo "  4. Nur lokaler Ping (ohne SSH zu Remote-Hosts):"
    echo "     cd ${ANSIBLE_DIR} && ansible-playbook playbooks/ping-local.yml"
    echo ""
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 6: Ansible installieren & Inventory"
    echo "=========================================="

    load_params

    read -rp "Ansible installieren und Inventory anlegen? (y/n) [y]: " confirm
    confirm="${confirm:-y}"
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    install_ansible
    create_ansible_structure
    collect_inventory_hosts
    create_group_vars
    create_ping_playbook
    print_usage

    log_info "Ansible-Setup abgeschlossen."
}

main "$@"
