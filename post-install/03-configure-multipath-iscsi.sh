#!/bin/bash
# =============================================================================
# Script 3: Multipath und iSCSI Discovery/Login konfigurieren
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
MPATH_CONF="/etc/multipath.conf"

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

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq open-iscsi multipath-tools sg3-utils 2>/dev/null || true
}

configure_multipath() {
    local vendor="${1:-}"

    [[ -f "$MPATH_CONF" ]] && cp "$MPATH_CONF" "${MPATH_CONF}.bak.$(date +%s)"

    cat > "$MPATH_CONF" << 'EOF'
defaults {
    user_friendly_names yes
    find_multipaths yes
    polling_interval 10
    path_selector "service-time 0"
    path_grouping_policy multibus
    failback immediate
    rr_min_io_rq 1
    no_path_retry 24
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    protocol "fc"
}

blacklist_exceptions {
}

devices {
    device {
        vendor "HP"
        product ".*"
        path_grouping_policy multibus
        path_checker tur
        hardware_handler "1 alua"
        features "0"
        no_path_retry 24
        prio alua
        failback immediate
        rr_weight uniform
    }
    device {
        vendor "HPE"
        product ".*"
        path_grouping_policy multibus
        path_checker tur
        hardware_handler "1 alua"
        features "0"
        no_path_retry 24
        prio alua
        failback immediate
        rr_weight uniform
    }
    device {
        vendor "COMPELNT"
        product ".*"
        path_grouping_policy multibus
        path_checker tur
        hardware_handler "1 alua"
        features "0"
        no_path_retry 24
        prio alua
        failback immediate
    }
    device {
        vendor "DELL"
        product ".*"
        path_grouping_policy multibus
        path_checker tur
        hardware_handler "1 alua"
        features "0"
        no_path_retry 24
        prio alua
        failback immediate
    }
    device {
        vendor "NETAPP"
        product ".*"
        path_grouping_policy multibus
        path_checker tur
        hardware_handler "1 alua"
        features "0"
        no_path_retry 24
        prio alua
        failback immediate
    }
}
EOF

    if [[ -n "$vendor" ]]; then
        log_info "Multipath für Vendor '${vendor}' konfiguriert"
    fi

    systemctl enable multipathd
    systemctl restart multipathd
    log_info "multipathd konfiguriert und gestartet"
}

discover_and_login() {
    local target_ip="$1"
    local target_port="${2:-3260}"

    log_info "iSCSI Discovery auf ${target_ip}:${target_port}..."

    if ! iscsiadm -m discovery -t sendtargets -p "${target_ip}:${target_port}" 2>/dev/null; then
        log_warn "Discovery fehlgeschlagen für ${target_ip}:${target_port}"
        return 1
    fi

    log_info "Automatischer Login für entdeckte Targets..."
    iscsiadm -m node --login 2>/dev/null || true

    # Node auf automatischen Start setzen
    iscsiadm -m node -o update -n node.startup -v automatic 2>/dev/null || true

    echo ""
    echo "Aktive iSCSI-Sessions:"
    iscsiadm -m session 2>/dev/null || echo "  Keine aktiven Sessions"
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 3: Multipath & iSCSI Konfiguration"
    echo "=========================================="

    load_params
    install_packages

    prompt STORAGE_VENDOR "Storage Vendor (HP/HPE/NETAPP/DELL, leer=alle)" ""

    configure_multipath "$STORAGE_VENDOR"

    echo ""
    echo "--- iSCSI Target Discovery ---"
    read -rp "iSCSI Targets jetzt discovern und einloggen? (y/n) [y]: " do_discover
    do_discover="${do_discover:-y}"

    if [[ "$do_discover" =~ ^[Yy]$ ]]; then
        while true; do
            prompt TARGET_IP "iSCSI Target IP" ""
            [[ -z "$TARGET_IP" ]] && break

            prompt TARGET_PORT "Port" "3260"
            discover_and_login "$TARGET_IP" "$TARGET_PORT"

            read -rp "Weiteres Target hinzufügen? (y/n) [n]: " more
            [[ "$more" =~ ^[Yy]$ ]] || break
        done
    fi

    echo ""
    echo "Multipath Status:"
    multipath -ll 2>/dev/null || echo "  Keine Multipath-Devices"

    echo ""
    log_info "Multipath/iSCSI Konfiguration abgeschlossen."
}

main "$@"
