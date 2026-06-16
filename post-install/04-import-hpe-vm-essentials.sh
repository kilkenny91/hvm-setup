#!/bin/bash
# =============================================================================
# Script 4: HPE VM Essentials installieren
#
# HPE liefert VM Essentials als ISO (keine OVA!). Die ISO enthält typischerweise:
#   - hpe-vm_*.deb          → VM Essentials Console (auf jedem HVM-Host)
#   - hpe-vme-*.qcow2(.gz)  → Manager-VM Image (nur auf einem Host)
#
# Dokumentation: https://hpevm-docs.morpheusdata.com/
# =============================================================================
set -euo pipefail

PARAMS_FILE="/root/install-params.env"
INSTALLER_DIR="/root/installers"
EXTRACT_DIR="/root/installers/vme-extracted"
MOUNT_POINT="/mnt/hpe-vme-iso"
CONFIG_FILE="/root/config/vme-install.env"

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
}

install_prerequisites() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq wget curl gzip 2>/dev/null || true
}

find_local_iso() {
    local candidates=(
        "${INSTALLER_DIR}/hpe-vm-essentials.iso"
        "${INSTALLER_DIR}/HPE_VM_Essentials_SW_Image.iso"
    )

    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    done

    find "$INSTALLER_DIR" -maxdepth 1 -type f -iname "*.iso" 2>/dev/null | head -1
}

fetch_iso_from_pxe() {
    local pxe_ip="$1"
    local dest_dir="$2"
    local base_url="http://${pxe_ip}/assets/installers"

    mkdir -p "$dest_dir"

    for name in hpe-vm-essentials.iso HPE_VM_Essentials_SW_Image.iso; do
        if wget -q --spider "${base_url}/${name}" 2>/dev/null; then
            local dest="${dest_dir}/${name}"
            wget -q --show-progress -O "$dest" "${base_url}/${name}"
            echo "$dest"
            return 0
        fi
    done

    local listing
    listing=$(curl -sf "${base_url}/" 2>/dev/null | grep -oE 'href="[^"]+\.iso"' | head -1 | cut -d'"' -f2)
    if [[ -n "$listing" ]]; then
        wget -q --show-progress -O "${dest_dir}/${listing}" "${base_url}/${listing}"
        echo "${dest_dir}/${listing}"
        return 0
    fi

    return 1
}

download_iso() {
    local url="$1"
    local dest_dir="$2"
    local filename

    mkdir -p "$dest_dir"
    filename=$(basename "$url" | cut -d'?' -f1)
    [[ -z "$filename" ]] && filename="hpe-vm-essentials.iso"

    log_info "Lade ISO von: $url"
    wget -q --show-progress -O "${dest_dir}/${filename}" "$url" || \
        curl -L -o "${dest_dir}/${filename}" "$url"
    echo "${dest_dir}/${filename}"
}

mount_iso() {
    local iso_file="$1"

    mkdir -p "$MOUNT_POINT"
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi

    mount -o loop,ro "$iso_file" "$MOUNT_POINT"
    log_info "ISO gemountet: ${iso_file} → ${MOUNT_POINT}"
}

unmount_iso() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
}

extract_iso_contents() {
    mkdir -p "$EXTRACT_DIR"

    local deb_file qcow_file qcow_gz
    deb_file=$(find "$MOUNT_POINT" -maxdepth 2 -type f -name "hpe-vm*.deb" 2>/dev/null | head -1)
    qcow_gz=$(find "$MOUNT_POINT" -maxdepth 2 -type f -name "*.qcow2.gz" 2>/dev/null | head -1)
    qcow_file=$(find "$MOUNT_POINT" -maxdepth 2 -type f -name "*.qcow2" ! -name "*.gz" 2>/dev/null | head -1)

    echo ""
    echo "Inhalt der ISO:"
    ls -lh "$MOUNT_POINT" 2>/dev/null || true
    echo ""

    if [[ -z "$deb_file" ]]; then
        log_error "Kein hpe-vm*.deb in der ISO gefunden."
        return 1
    fi

    log_info "Debian-Paket: ${deb_file}"
    cp "$deb_file" "${EXTRACT_DIR}/"

    DEB_PACKAGE="${EXTRACT_DIR}/$(basename "$deb_file")"

    if [[ -n "$qcow_gz" ]]; then
        log_info "Manager-Image (komprimiert): ${qcow_gz}"
        cp "$qcow_gz" "${EXTRACT_DIR}/"
        QCOW_GZ="${EXTRACT_DIR}/$(basename "$qcow_gz")"
    elif [[ -n "$qcow_file" ]]; then
        log_info "Manager-Image: ${qcow_file}"
        cp "$qcow_file" "${EXTRACT_DIR}/"
        QCOW_IMAGE="${EXTRACT_DIR}/$(basename "$qcow_file")"
    else
        log_warn "Kein QCOW2-Image in der ISO gefunden (nur relevant für Manager-Host)."
    fi
}

install_console_package() {
    log_info "Installiere VM Essentials Console (.deb)..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -f "$DEB_PACKAGE"

    if command -v hpe-vm >/dev/null 2>&1; then
        log_info "hpe-vm Console installiert."
    else
        log_warn "Paket installiert, aber 'hpe-vm' Befehl nicht gefunden."
    fi
}

prepare_manager_image() {
    local dest="${INSTALLER_DIR}/manager"

    mkdir -p "$dest"

    if [[ -n "${QCOW_GZ:-}" && -f "$QCOW_GZ" ]]; then
        log_info "Entpacke Manager-Image..."
        gunzip -kf "$QCOW_GZ"
        QCOW_IMAGE="${QCOW_GZ%.gz}"
        cp "$QCOW_IMAGE" "${dest}/"
        QCOW_IMAGE="${dest}/$(basename "$QCOW_IMAGE")"
    elif [[ -n "${QCOW_IMAGE:-}" && -f "$QCOW_IMAGE" ]]; then
        cp "$QCOW_IMAGE" "${dest}/"
        QCOW_IMAGE="${dest}/$(basename "$QCOW_IMAGE")"
    else
        return 1
    fi

    log_info "Manager-Image bereit: ${QCOW_IMAGE}"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# HPE VM Essentials – generiert von 04-install-hpe-vm-essentials.sh
ISO_FILE=${ISO_FILE:-}
DEB_PACKAGE=${DEB_PACKAGE:-}
QCOW_IMAGE=${QCOW_IMAGE:-}
IS_MANAGER_HOST=${IS_MANAGER_HOST:-false}
HOSTNAME=${HOSTNAME:-$(hostname -s)}
EOF
    chmod 600 "$CONFIG_FILE"
    log_info "Konfiguration gespeichert: ${CONFIG_FILE}"
}

print_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Nächste Schritte (HPE VM Essentials)"
    echo "=========================================="
    echo ""
    echo "1. Console auf ALLEN HVM-Hosts konfigurieren:"
    echo "     hpe-vm"
    echo "   → Timezone, Netzwerk (MTU, Storage-Interfaces), speichern"
    echo ""
    echo "2. .deb auf weitere Cluster-Hosts (Script 8):"
    echo "     /root/post-install/08-deploy-vme-console-deb.sh"
    echo ""

    if [[ "${IS_MANAGER_HOST:-false}" == "true" && -n "${QCOW_IMAGE:-}" ]]; then
        echo "3. Manager auf DIESEM Host installieren:"
        echo "     hpe-vm"
        echo "   → 'Install Morpheus' wählen"
        echo "   → Image URI: file://${QCOW_IMAGE}"
        echo ""
        prompt MGR_IP "Manager IP-Adresse" "${IP_ADDRESS:-}"
        prompt MGR_GATEWAY "Manager Gateway" "${GATEWAY:-}"
        prompt MGR_URL "Appliance URL (HTTPS)" "https://${HOSTNAME:-vme-manager}.${DOMAIN:-local}"
        prompt MGMT_IFACE "Management-Interface" "bond0.${VLAN_ID:-1}"
        prompt COMPUTE_IFACE "Compute-Interface" "bond0"

        cat >> "$CONFIG_FILE" << EOF
MANAGER_IP=${MGR_IP:-}
MANAGER_GATEWAY=${MGR_GATEWAY:-}
MANAGER_URL=${MGR_URL:-}
MANAGER_IMAGE_URI=file://${QCOW_IMAGE}
MGMT_INTERFACE=${MGMT_IFACE:-}
COMPUTE_INTERFACE=${COMPUTE_IFACE:-}
EOF

        echo ""
        echo "   Im hpe-vm Wizard eintragen:"
        echo "     Image URI:  file://${QCOW_IMAGE}"
        echo "     IP:         ${MGR_IP:-}"
        echo "     Gateway:    ${MGR_GATEWAY:-}"
        echo "     Appliance:  ${MGR_URL:-}"
        echo "     Mgmt IF:    ${MGMT_IFACE:-}"
        echo "     Compute IF: ${COMPUTE_IFACE:-}"
    else
        echo "3. Manager-Installation erfolgt auf EINEM Host mit QCOW2-Image."
        echo "   Dort Script 4 erneut ausführen und 'Manager-Host' wählen."
    fi

    echo ""
    echo "4. Nach Manager-Start: Browser → Appliance URL → Lizenz & Setup"
    echo ""
    read -rp "hpe-vm Console jetzt starten? (y/n) [n]: " launch
    launch="${launch:-n}"
    if [[ "$launch" =~ ^[Yy]$ ]] && command -v hpe-vm >/dev/null 2>&1; then
        hpe-vm
    fi
}

resolve_iso_file() {
    local default_local
    default_local=$(find_local_iso 2>/dev/null || true)

    echo ""
    echo "HPE VM Essentials wird als ISO geliefert (enthält .deb + QCOW2)."
    echo "Quellen: lokal, PXE-Server HTTP, oder Download-URL."
    echo ""

    prompt DOWNLOAD_URL "Download-URL (ISO, leer = lokal/PXE)" ""

    if [[ -n "$DOWNLOAD_URL" ]]; then
        ISO_FILE=$(download_iso "$DOWNLOAD_URL" "$INSTALLER_DIR")
    else
        prompt LOCAL_FILE "Pfad zur ISO-Datei" "${default_local:-${INSTALLER_DIR}/hpe-vm-essentials.iso}"

        if [[ -f "$LOCAL_FILE" ]]; then
            ISO_FILE="$LOCAL_FILE"
        else
            log_warn "ISO nicht gefunden: ${LOCAL_FILE}"
            prompt PXE_SERVER_IP "PXE-Server IP (ISO per HTTP laden)" "${GATEWAY:-}"
            ISO_FILE=$(fetch_iso_from_pxe "$PXE_SERVER_IP" "$INSTALLER_DIR") || {
                log_error "ISO nicht gefunden."
                echo ""
                echo "Bitte ISO bereitstellen unter:"
                echo "  Projekt:  installers/hpe-vm-essentials.iso"
                echo "  HVM-Host: /root/installers/hpe-vm-essentials.iso"
                exit 1
            }
        fi
    fi
}

main() {
    echo ""
    echo "=========================================="
    echo "  Script 4: HPE VM Essentials installieren"
    echo "=========================================="

    load_params
    install_prerequisites

    resolve_iso_file

    trap unmount_iso EXIT
    mount_iso "$ISO_FILE"
    extract_iso_contents

    echo ""
    read -rp "VM Essentials Console (.deb) jetzt installieren? (y/n) [y]: " do_install
    do_install="${do_install:-y}"
    if [[ "$do_install" =~ ^[Yy]$ ]]; then
        install_console_package
    fi

    echo ""
    read -rp "Ist dies der Manager-Host (QCOW2-Image entpacken)? (y/n) [n]: " is_mgr
    is_mgr="${is_mgr:-n}"
    if [[ "$is_mgr" =~ ^[Yy]$ ]]; then
        IS_MANAGER_HOST=true
        prepare_manager_image || log_warn "Manager-Image konnte nicht vorbereitet werden."
    fi

    save_config
    print_next_steps

    log_info "HPE VM Essentials Vorbereitung abgeschlossen."
}

main "$@"
