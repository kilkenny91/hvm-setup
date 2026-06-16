#!/bin/bash
# =============================================================================
# Script 7: SSH-Key-Exchange und SSH-Konfiguration für Ansible
# - SSH-Key generieren (ed25519)
# - known_hosts via ssh-keyscan
# - Public Key auf Remote-Hosts verteilen (ssh-copy-id)
# - ~/.ssh/config für Inventory-Hosts
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
ANSIBLE_DIR="/root/ansible"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts"
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"
SSH_CONFIG="${SSH_DIR}/config"

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
}

install_prerequisites() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssh-client sshpass 2>/dev/null || \
        apt-get install -y openssh-client sshpass
}

generate_ssh_key() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -f "$SSH_KEY" ]]; then
        log_warn "SSH-Key existiert bereits: ${SSH_KEY}"
        read -rp "Neuen Key erzeugen? (y/n) [n]: " regen
        regen="${regen:-n}"
        [[ "$regen" =~ ^[Yy]$ ]] || return 0
    fi

    local key_comment
    key_comment="${HOSTNAME:-$(hostname -s)}-ansible"
    prompt key_comment "Key-Kommentar" "$key_comment"

    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${key_comment}@$(hostname -f 2>/dev/null || hostname)"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"

    log_info "SSH-Key erzeugt: ${SSH_KEY}"
}

parse_inventory_hosts() {
    # Gibt Zeilen aus: alias|ip|user|port
    local inv_file="$1"

    if [[ ! -f "$inv_file" ]]; then
        return 1
    fi

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
    echo "Kein Inventory gefunden. Hosts manuell eingeben (leerer Hostname = fertig):"
    while true; do
        local alias ip user port entry
        prompt alias "  Hostname/Alias" ""
        [[ -z "$alias" ]] && break
        prompt ip "  IP-Adresse" ""
        prompt user "  SSH-Benutzer" "root"
        prompt port "  SSH-Port" "22"
        hosts+=("${alias}|${ip}|${user}|${port}")
    done
    printf '%s\n' "${hosts[@]}"
}

add_known_hosts() {
    local ip="$1" port="$2"

    log_info "ssh-keyscan: ${ip}:${port}"
    ssh-keyscan -p "$port" -H "$ip" >> "${SSH_DIR}/known_hosts" 2>/dev/null || \
        log_warn "ssh-keyscan fehlgeschlagen für ${ip}"
}

create_ssh_config_entry() {
    local alias="$1" ip="$2" user="$3" port="$4"

    if [[ -f "$SSH_CONFIG" ]] && grep -q "^Host ${alias}$" "$SSH_CONFIG" 2>/dev/null; then
        return 0
    fi

    cat >> "$SSH_CONFIG" << EOF

Host ${alias}
    HostName ${ip}
    User ${user}
    Port ${port}
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
}

copy_ssh_key() {
    local alias="$1" ip="$2" user="$3" port="$4"
    local ssh_password="${5:-}"

    log_info "Verteile SSH-Key auf ${user}@${ip} (${alias})..."

    if ssh -i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 \
        "${user}@${ip}" "echo ok" &>/dev/null; then
        log_info "  Bereits per Key erreichbar."
        return 0
    fi

    if [[ -n "$ssh_password" ]] && command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$ssh_password" sshpass -e ssh-copy-id \
            -i "${SSH_KEY}.pub" \
            -p "$port" \
            -o StrictHostKeyChecking=accept-new \
            "${user}@${ip}" 2>/dev/null && return 0
    fi

    # Interaktiv
    ssh-copy-id -i "${SSH_KEY}.pub" -p "$port" \
        -o StrictHostKeyChecking=accept-new \
        "${user}@${ip}" || {
        log_warn "  ssh-copy-id fehlgeschlagen für ${alias} (${ip})"
        return 1
    }
}

test_ssh_connectivity() {
    local alias="$1" ip="$2" user="$3" port="$4"

    if ssh -i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 \
        "${user}@${ip}" "hostname" &>/dev/null; then
        log_info "  SSH-Test OK: ${alias} (${user}@${ip})"
        return 0
    else
        log_warn "  SSH-Test FEHLGESCHLAGEN: ${alias} (${user}@${ip})"
        return 1
    fi
}

setup_ssh_agent() {
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
        ssh-add "$SSH_KEY" 2>/dev/null || true
        log_info "SSH-Agent gestartet und Key geladen"
    fi
}

run_ansible_ping_test() {
    if [[ ! -f "${ANSIBLE_DIR}/playbooks/ping.yml" ]]; then
        return 0
    fi

    if ! command -v ansible-playbook >/dev/null 2>&1; then
        log_warn "ansible-playbook nicht gefunden – Ping-Test übersprungen"
        return 0
    fi

    echo ""
    read -rp "Ansible Ping-Playbook jetzt ausführen? (y/n) [y]: " do_ping
    do_ping="${do_ping:-y}"
    if [[ "$do_ping" =~ ^[Yy]$ ]]; then
        cd "$ANSIBLE_DIR"
        ansible-playbook playbooks/ping.yml
    fi
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 7: SSH-Setup für Ansible"
    echo "=========================================="

    load_params
    install_prerequisites
    generate_ssh_key
    setup_ssh_agent

    touch "${SSH_DIR}/known_hosts"
    chmod 600 "${SSH_DIR}/known_hosts"

    # SSH config Header
    if [[ ! -f "$SSH_CONFIG" ]]; then
        cat > "$SSH_CONFIG" << EOF
# Generiert von 07-setup-ssh-for-ansible.sh
# Ansible SSH-Konfiguration

Host *
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
EOF
        chmod 600 "$SSH_CONFIG"
    fi

    local host_lines=()
    if [[ -f "$INVENTORY_FILE" ]]; then
        log_info "Lese Hosts aus Inventory: ${INVENTORY_FILE}"
        mapfile -t host_lines < <(parse_inventory_hosts "$INVENTORY_FILE")
    fi

    if [[ ${#host_lines[@]} -eq 0 ]]; then
        log_warn "Keine Remote-Hosts im Inventory."
        mapfile -t host_lines < <(collect_hosts_interactive)
    fi

    if [[ ${#host_lines[@]} -eq 0 ]]; then
        log_warn "Keine Remote-Hosts konfiguriert. Nur lokaler Key erstellt."
        exit 0
    fi

    echo ""
    echo "Folgende Remote-Hosts werden konfiguriert:"
    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        echo "  - ${alias}: ${user}@${ip}:${port}"
    done
    echo ""

    local use_password="n" ssh_password=""
    read -rp "SSH-Passwort für ssh-copy-id verwenden (sshpass)? (y/n) [n]: " use_password
    use_password="${use_password:-n}"
    if [[ "$use_password" =~ ^[Yy]$ ]]; then
        prompt_secret ssh_password "SSH-Passwort (für alle Hosts gleich)"
    fi

    local failed=0
    for line in "${host_lines[@]}"; do
        IFS='|' read -r alias ip user port <<< "$line"
        [[ -z "$ip" ]] && continue

        add_known_hosts "$ip" "$port"
        create_ssh_config_entry "$alias" "$ip" "$user" "$port"
        copy_ssh_key "$alias" "$ip" "$user" "$port" "$ssh_password" || failed=$((failed + 1))
        test_ssh_connectivity "$alias" "$ip" "$user" "$port" || failed=$((failed + 1))
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        log_info "SSH-Setup für alle Hosts erfolgreich."
    else
        log_warn "${failed} Host(s) mit Problemen – manuell prüfen."
    fi

    echo ""
    echo "SSH-Konfiguration:"
    echo "  Key:    ${SSH_KEY}"
    echo "  Config: ${SSH_CONFIG}"
    echo ""

    run_ansible_ping_test
    log_info "SSH-Setup abgeschlossen."
}

main "$@"
