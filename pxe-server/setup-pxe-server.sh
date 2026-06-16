#!/bin/bash
# =============================================================================
# HPE HVM PXE Server Setup
# Richtet dnsmasq (DHCP+TFTP), nginx (HTTP) und iPXE für HVM-Installation ein
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pxe-server.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dieses Skript muss als root ausgeführt werden (sudo)."
        exit 1
    fi
}

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="${3:-}"
    local input

    if [[ -n "$default_value" ]]; then
        read -rp "${prompt_text} [${default_value}]: " input
        input="${input:-$default_value}"
    else
        read -rp "${prompt_text}: " input
        while [[ -z "$input" ]]; do
            read -rp "${prompt_text} (Pflichtfeld): " input
        done
    fi
    printf -v "$var_name" '%s' "$input"
}

detect_interface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || \
        ip -4 addr show | awk '/^[0-9]+:/ {iface=$2; gsub(/:/,"",iface)} /inet / {print iface; exit}'
}

detect_ip() {
    local iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

install_packages() {
    log_info "Installiere benötigte Pakete..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        dnsmasq \
        nginx \
        tftpd-hpa \
        syslinux \
        syslinux-common \
        pxelinux \
        curl \
        wget \
        jq \
        ipxe \
        net-tools \
        python3-yaml \
        2>/dev/null || {
        apt-get install -y dnsmasq nginx tftpd-hpa syslinux syslinux-common pxelinux \
            curl wget jq net-tools python3-yaml
        # ipxe Paket optional
        apt-get install -y ipxe 2>/dev/null || log_warn "ipxe Paket nicht verfügbar, verwende eingebettete iPXE-Binaries"
    }
}

collect_user_input() {
    echo ""
    echo "=========================================="
    echo "  HPE HVM PXE-Server Konfiguration"
    echo "=========================================="
    echo ""

    local default_iface default_ip
    default_iface="$(detect_interface)"
    default_ip="$(detect_ip "$default_iface" 2>/dev/null || echo "")"

    prompt PXE_INTERFACE "Netzwerk-Interface des PXE-Servers" "$default_iface"
    prompt PXE_SERVER_IP "IP-Adresse des PXE-Servers" "$default_ip"
    prompt DHCP_RANGE_START "DHCP Range Start" "192.168.100.100"
    prompt DHCP_RANGE_END "DHCP Range End" "192.168.100.200"
    prompt DHCP_SUBNET_MASK "Subnetzmaske" "255.255.255.0"
    prompt DHCP_GATEWAY "Gateway" "${PXE_SERVER_IP%.*}.1"
    prompt DHCP_DNS "DNS-Server" "$DHCP_GATEWAY"
    prompt DOMAIN "Domain" "local"

    echo ""
    read -rp "Pfad zur HPE HVM ISO [${PROJECT_ROOT}/iso/hpe-hvm.iso]: " ISO_PATH
    ISO_PATH="${ISO_PATH:-${PROJECT_ROOT}/iso/hpe-hvm.iso}"

    if [[ ! -f "$ISO_PATH" ]]; then
        log_warn "ISO nicht gefunden: $ISO_PATH"
        read -rp "ISO-Pfad jetzt angeben oder später bereitstellen? (Pfad eingeben oder Enter zum Überspringen): " ISO_PATH_RETRY
        if [[ -n "$ISO_PATH_RETRY" ]]; then
            ISO_PATH="$ISO_PATH_RETRY"
        fi
    fi

    TFTP_ROOT="/var/lib/tftpboot"
    HTTP_ROOT="/var/www/hvm-pxe"
    INSTALL_ROOT="/opt/hvm-pxe"
    DHCP_LEASE_TIME="12h"
    MGMT_BOND_MODE="802.3ad"
    ISCSI_IQN_PREFIX="iqn.$(date +%Y-%m)-01.com.hpe"

    mkdir -p "${PROJECT_ROOT}/config"
    cat > "$CONFIG_FILE" << EOF
PXE_INTERFACE="${PXE_INTERFACE}"
PXE_SERVER_IP="${PXE_SERVER_IP}"
DHCP_RANGE_START="${DHCP_RANGE_START}"
DHCP_RANGE_END="${DHCP_RANGE_END}"
DHCP_SUBNET_MASK="${DHCP_SUBNET_MASK}"
DHCP_GATEWAY="${DHCP_GATEWAY}"
DHCP_DNS="${DHCP_DNS}"
DHCP_LEASE_TIME="${DHCP_LEASE_TIME}"
ISO_PATH="${ISO_PATH}"
TFTP_ROOT="${TFTP_ROOT}"
HTTP_ROOT="${HTTP_ROOT}"
INSTALL_ROOT="${INSTALL_ROOT}"
DOMAIN="${DOMAIN}"
MGMT_BOND_MODE="${MGMT_BOND_MODE}"
ISCSI_IQN_PREFIX="${ISCSI_IQN_PREFIX}"
EOF
    log_info "Konfiguration gespeichert: $CONFIG_FILE"
}

setup_directories() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "Erstelle Verzeichnisstruktur..."
    mkdir -p "$TFTP_ROOT"/{pxelinux.cfg,bios,uefi/grub,images,hvm,ipxe}
    mkdir -p "$HTTP_ROOT"/{hosts,iso,cgi-bin,assets/post-install,assets/installers}
    mkdir -p "$INSTALL_ROOT"/{iso,boot,config,scripts}
    mkdir -p "${PROJECT_ROOT}/config"

    if [[ ! -f "${PROJECT_ROOT}/config/interfaces.yaml" ]]; then
        cp "${PROJECT_ROOT}/config/interfaces.example.yaml" "${PROJECT_ROOT}/config/interfaces.yaml"
        log_info "interfaces.yaml aus Beispiel erstellt"
    fi

    # Projektdateien nach INSTALL_ROOT kopieren
    cp -r "${PROJECT_ROOT}/post-install" "$INSTALL_ROOT/"
    cp -r "${PROJECT_ROOT}/post-install/"* "$HTTP_ROOT/assets/post-install/" 2>/dev/null || true
    [[ -d "${PROJECT_ROOT}/post-install/ops-vm" ]] && \
        cp -a "${PROJECT_ROOT}/post-install/ops-vm" "$HTTP_ROOT/assets/post-install/"
    if compgen -G "${PROJECT_ROOT}/installers/*" >/dev/null 2>&1; then
        cp -r "${PROJECT_ROOT}/installers/"* "$HTTP_ROOT/assets/installers/" 2>/dev/null || true
        log_info "Installer nach ${HTTP_ROOT}/assets/installers/ kopiert"
    fi
    cp -r "${PROJECT_ROOT}/autoinstall" "$INSTALL_ROOT/"
    cp -r "${PROJECT_ROOT}/pxe-server/ipxe" "$INSTALL_ROOT/"
    cp "${PROJECT_ROOT}/pxe-server/prepare-host.sh" "$INSTALL_ROOT/scripts/"
    cp "${PROJECT_ROOT}/pxe-server/generate-autoinstall.sh" "$INSTALL_ROOT/scripts/"
    chmod +x "$INSTALL_ROOT/scripts/"*.sh
    chmod +x "$INSTALL_ROOT/post-install/"*.sh
    cp "${PROJECT_ROOT}/config/interfaces.yaml" "$INSTALL_ROOT/config/"
}

setup_tftp() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "Konfiguriere TFTP/PXELinux..."

    # PXELinux Dateien
    local pxelinux_paths=(
        /usr/lib/PXELINUX/pxelinux.0
        /usr/lib/syslinux/modules/bios/pxelinux.0
        /usr/share/syslinux/pxelinux.0
    )
    for p in "${pxelinux_paths[@]}"; do
        if [[ -f "$p" ]]; then
            cp "$p" "$TFTP_ROOT/"
            break
        fi
    done

    local ldlinux_paths=(
        /usr/lib/syslinux/modules/bios/ldlinux.c32
        /usr/share/syslinux/ldlinux.c32
    )
    for p in "${ldlinux_paths[@]}"; do
        if [[ -f "$p" ]]; then
            cp "$p" "$TFTP_ROOT/"
            break
        fi
    done

    # Weitere benötigte Module
    for mod in menu.c32 libutil.c32 libcom32.c32; do
        for base in /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
            if [[ -f "${base}/${mod}" ]]; then
                cp "${base}/${mod}" "$TFTP_ROOT/"
                break
            fi
        done
    done

    # iPXE Binaries
    for ipxe_bin in undionly.kpxe ipxe.efi; do
        for base in /usr/lib/ipxe /usr/share/ipxe /usr/lib/syslinux/modules/bios; do
            if [[ -f "${base}/${ipxe_bin}" ]]; then
                cp "${base}/${ipxe_bin}" "$TFTP_ROOT/"
                break
            fi
        done
    done

    # PXELinux default -> chainload iPXE
    cat > "$TFTP_ROOT/pxelinux.cfg/default" << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 100
ONTIMEOUT ipxe

MENU TITLE HPE HVM PXE Boot

LABEL ipxe
    MENU LABEL HPE HVM Installation (iPXE)
    KERNEL ipxe/undionly.kpxe
    APPEND -p ${PXE_SERVER_IP} ipxe/menu.ipxe

LABEL ipxe-efi
    MENU LABEL HPE HVM Installation (UEFI/iPXE)
    KERNEL ipxe/ipxe.efi
    APPEND -p ${PXE_SERVER_IP} ipxe/menu.ipxe

LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0
EOF

    # iPXE Skripte
    cp -r "${INSTALL_ROOT}/ipxe/"* "$TFTP_ROOT/ipxe/"
    sed -i "s|@PXE_SERVER_IP@|${PXE_SERVER_IP}|g" "$TFTP_ROOT/ipxe/"*.ipxe
}

setup_dnsmasq() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "Konfiguriere dnsmasq (DHCP + TFTP)..."

    # Bestehende dnsmasq stoppen falls aktiv
    systemctl stop dnsmasq 2>/dev/null || true

    # Backup
    [[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s)

    cat > /etc/dnsmasq.d/hvm-pxe.conf << EOF
# HPE HVM PXE Server - generiert von setup-pxe-server.sh
interface=${PXE_INTERFACE}
bind-interfaces
except-interface=lo

# DHCP
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_SUBNET_MASK},${DHCP_LEASE_TIME}
dhcp-option=option:router,${DHCP_GATEWAY}
dhcp-option=option:dns-server,${DHCP_DNS}
dhcp-authoritative

# PXE / TFTP
enable-tftp
tftp-root=${TFTP_ROOT}

# BIOS PXE
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0,${PXE_SERVER_IP}

# UEFI x64
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,ipxe/ipxe.efi,${PXE_SERVER_IP}

# Logging
log-dhcp
log-queries
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq
}

setup_nginx() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    log_info "Konfiguriere nginx (HTTP für Autoinstall + ISO)..."

    cat > /etc/nginx/sites-available/hvm-pxe << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root ${HTTP_ROOT};
    autoindex on;

    # Autoinstall user-data pro Host
    location /hosts/ {
        alias ${HTTP_ROOT}/hosts/;
        default_type text/plain;
    }

    # ISO und Boot-Dateien
    location /iso/ {
        alias ${HTTP_ROOT}/iso/;
    }

    location /boot/ {
        alias ${HTTP_ROOT}/boot/;
    }

    # API: Host vorbereiten (iPXE)
    location /api/prepare-host {
        default_type text/plain;
        include fastcgi_params;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME ${HTTP_ROOT}/cgi-bin/prepare-host.sh;
    }

    # iPXE Skripte auch per HTTP
    location /ipxe/ {
        alias ${TFTP_ROOT}/ipxe/;
        default_type text/plain;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/hvm-pxe /etc/nginx/sites-enabled/hvm-pxe
    rm -f /etc/nginx/sites-enabled/default

    # fcgiwrap für CGI
    apt-get install -y -qq fcgiwrap 2>/dev/null || true
    cp "${PROJECT_ROOT}/pxe-server/prepare-host.sh" "${HTTP_ROOT}/cgi-bin/prepare-host.sh"
    chmod +x "${HTTP_ROOT}/cgi-bin/prepare-host.sh"

    systemctl enable nginx fcgiwrap 2>/dev/null || true
    systemctl restart fcgiwrap nginx 2>/dev/null || systemctl restart nginx
}

extract_iso_if_present() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    if [[ -f "$ISO_PATH" ]]; then
        log_info "Extrahiere Boot-Dateien aus ISO..."
        bash "${SCRIPT_DIR}/extract-iso.sh"
    else
        log_warn "ISO nicht vorhanden. Nach Bereitstellung ausführen: sudo ${SCRIPT_DIR}/extract-iso.sh"
    fi
}

print_summary() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    echo ""
    echo "=========================================="
    echo -e "  ${GREEN}PXE-Server Setup abgeschlossen${NC}"
    echo "=========================================="
    echo ""
    echo "  Server IP:     ${PXE_SERVER_IP}"
    echo "  DHCP Range:    ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
    echo "  TFTP Root:     ${TFTP_ROOT}"
    echo "  HTTP Root:     ${HTTP_ROOT}"
    echo "  ISO Pfad:      ${ISO_PATH}"
    echo ""
    echo "  Nächste Schritte:"
    echo "  1. interfaces.yaml anpassen: ${PROJECT_ROOT}/config/interfaces.yaml"
    echo "  2. ISO bereitstellen (falls noch nicht): ${ISO_PATH}"
    echo "  3. extract-iso.sh ausführen: sudo ${SCRIPT_DIR}/extract-iso.sh"
    echo "  4. Ziel-Server per PXE booten"
    echo ""
    echo "  Host manuell registrieren:"
    echo "    sudo ${SCRIPT_DIR}/register-host.sh"
    echo ""
    echo "  Status prüfen:"
    echo "    systemctl status dnsmasq nginx"
    echo "    journalctl -u dnsmasq -f"
    echo ""
}

main() {
    require_root
    collect_user_input
    install_packages
    setup_directories
    setup_tftp
    setup_dnsmasq
    setup_nginx
    extract_iso_if_present
    print_summary
}

main "$@"
