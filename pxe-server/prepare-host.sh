#!/bin/bash
# =============================================================================
# CGI/API Endpoint: Host aus iPXE-Parametern vorbereiten
# Wird von nginx+fcgiwrap aufgerufen oder direkt per curl
# =============================================================================
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/hvm-pxe}"
PROJECT_ROOT="${INSTALL_ROOT}"
SCRIPT_DIR="${INSTALL_ROOT}/scripts"
GENERATE_SCRIPT="${SCRIPT_DIR}/generate-autoinstall.sh"

# Fallback Pfade
[[ -f "$GENERATE_SCRIPT" ]] || GENERATE_SCRIPT="$(dirname "$0")/generate-autoinstall.sh"
[[ -f "$GENERATE_SCRIPT" ]] || GENERATE_SCRIPT="/var/www/hvm-pxe/cgi-bin/../generate-autoinstall.sh"

# Query-String parsen (CGI oder direkt)
if [[ -n "${QUERY_STRING:-}" ]]; then
    PARAMS="$QUERY_STRING"
elif [[ -n "${1:-}" ]]; then
    PARAMS="$1"
else
    PARAMS=""
fi

parse_param() {
    local key="$1" default="${2:-}"
    echo "$PARAMS" | tr '&' '\n' | grep "^${key}=" | cut -d= -f2- | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 printf '%b' 2>/dev/null || echo "$default"
}

hostname=$(parse_param "hostname")
ip=$(parse_param "ip")
netmask=$(parse_param "netmask" "255.255.255.0")
gateway=$(parse_param "gateway")
vlan=$(parse_param "vlan" "1")
profile=$(parse_param "profile" "default")

# CGI Header
if [[ -n "${GATEWAY_INTERFACE:-}" ]] || [[ -n "${REQUEST_METHOD:-}" ]]; then
    echo "Content-Type: text/plain"
    echo ""
fi

if [[ -z "$hostname" || -z "$ip" || -z "$gateway" ]]; then
    echo "ERROR: Fehlende Parameter. Erforderlich: hostname, ip, gateway"
    echo "Optional: netmask, vlan, profile"
    exit 1
fi

# Hostname validieren
if ! echo "$hostname" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]*$'; then
    echo "ERROR: Ungültiger Hostname: $hostname"
    exit 1
fi

if [[ ! -x "$GENERATE_SCRIPT" ]]; then
    GENERATE_SCRIPT="$(dirname "$0")/../generate-autoinstall.sh"
fi

if [[ ! -f "$GENERATE_SCRIPT" ]]; then
    echo "ERROR: generate-autoinstall.sh nicht gefunden"
    exit 1
fi

bash "$GENERATE_SCRIPT" "$hostname" "$ip" "$netmask" "$gateway" "$vlan" "$profile"

echo ""
echo "OK: Host ${hostname} vorbereitet."
echo "Autoinstall URL: http://$(hostname -I | awk '{print $1}')/hosts/${hostname}/"
