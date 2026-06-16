#!/bin/bash
# =============================================================================
# Script 2: iSCSI Initiator IQN konfigurieren
# IQN wird automatisch aus Hostname zusammengesetzt
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
ISCSID_CONF="/etc/iscsi/initiatorname.iscsi"

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

generate_iqn() {
    local hostname="$1"
    local prefix="${ISCSI_IQN_PREFIX:-iqn.$(date +%Y-%m)-01.com.hpe}"
    local hostname_lower
    hostname_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    echo "${prefix}:${hostname_lower}"
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 2: iSCSI IQN konfigurieren"
    echo "=========================================="

    load_params

    local default_hostname
    default_hostname="${HOSTNAME:-$(hostname -s)}"
    prompt HOSTNAME "Hostname" "$default_hostname"
    prompt ISCSI_IQN_PREFIX "IQN Prefix" "${ISCSI_IQN_PREFIX:-iqn.$(date +%Y-%m)-01.com.hpe}"

    local iqn
    iqn=$(generate_iqn "$HOSTNAME")

    echo ""
    echo "Generierter IQN: ${iqn}"
    read -rp "IQN verwenden? (y/n) [y]: " confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        prompt iqn "IQN manuell eingeben" "$iqn"
    fi

    # Backup
    [[ -f "$ISCSID_CONF" ]] && cp "$ISCSID_CONF" "${ISCSID_CONF}.bak.$(date +%s)"

    echo "InitiatorName=${iqn}" > "$ISCSID_CONF"
    log_info "IQN gesetzt in $ISCSID_CONF"

    # iscsid neu starten
    systemctl restart iscsid 2>/dev/null || service iscsid restart 2>/dev/null || true
    log_info "iscsid Dienst neu gestartet"

    echo ""
    echo "Aktuelle Konfiguration:"
    cat "$ISCSID_CONF"
}

main "$@"
