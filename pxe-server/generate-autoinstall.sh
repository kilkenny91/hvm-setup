#!/bin/bash
# =============================================================================
# Generiert Ubuntu Autoinstall user-data aus Template und Host-Parametern
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pxe-server.conf"
INTERFACES_FILE="${PROJECT_ROOT}/config/interfaces.yaml"
TEMPLATE="${PROJECT_ROOT}/autoinstall/templates/user-data.template"

# Parameter (via Umgebungsvariablen oder Argumente)
HOSTNAME="${1:-${HOSTNAME:-}}"
IP_ADDRESS="${2:-${IP_ADDRESS:-}}"
NETMASK="${3:-${NETMASK:-255.255.255.0}}"
GATEWAY="${4:-${GATEWAY:-}}"
VLAN_ID="${5:-${VLAN_ID:-1}}"
INTERFACE_PROFILE="${6:-${INTERFACE_PROFILE:-default}}"
ROOT_PASSWORD="${ROOT_PASSWORD:-hvmadmin}"
OUTPUT_DIR="${7:-${OUTPUT_DIR:-}}"

log_error() { echo "ERROR: $*" >&2; }

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

HTTP_ROOT="${HTTP_ROOT:-/var/www/hvm-pxe}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/hvm-pxe}"
INTERFACES_FILE="${INSTALL_ROOT}/config/interfaces.yaml"
[[ -f "$INTERFACES_FILE" ]] || INTERFACES_FILE="${PROJECT_ROOT}/config/interfaces.yaml"
TEMPLATE="${INSTALL_ROOT}/autoinstall/templates/user-data.template"
[[ -f "$TEMPLATE" ]] || TEMPLATE="${PROJECT_ROOT}/autoinstall/templates/user-data.template"

if [[ -z "$HOSTNAME" || -z "$IP_ADDRESS" || -z "$GATEWAY" ]]; then
    log_error "Verwendung: $0 <hostname> <ip> <netmask> <gateway> <vlan_id> [profile] [output_dir]"
    exit 1
fi

# CIDR aus Netzmaske berechnen
netmask_to_cidr() {
    local mask="$1" cidr=0 IFS=.
    read -r i1 i2 i3 i4 <<< "$mask"
    for octet in $i1 $i2 $i3 $i4; do
        while [[ $octet -gt 0 ]]; do
            cidr=$((cidr + octet % 2))
            octet=$((octet / 2))
        done
    done
    echo "$cidr"
}

CIDR=$(netmask_to_cidr "$NETMASK")
DNS_SERVERS="${DHCP_DNS:-$GATEWAY}"

# Interfaces aus YAML-Profil lesen
read_interfaces() {
    local profile="$1"
    python3 - "$INTERFACES_FILE" "$profile" << 'PYEOF'
import sys, yaml

interfaces_file, profile = sys.argv[1], sys.argv[2]
try:
    with open(interfaces_file) as f:
        data = yaml.safe_load(f)
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)

profiles = data.get("profiles", {})
if profile not in profiles:
    profile = "default"
    if profile not in profiles:
        print("ERROR:Profil nicht gefunden", file=sys.stderr)
        sys.exit(1)

p = profiles[profile]
mgmt = p.get("mgmt", [])
vm = p.get("vm_traffic", [])
storage = p.get("storage", [])

print("MGMT=" + ",".join(mgmt))
print("VM=" + ",".join(vm))
print("STORAGE=" + ",".join(storage))
PYEOF
}

IFACE_VARS=$(read_interfaces "$INTERFACE_PROFILE")
eval "$(echo "$IFACE_VARS" | grep -E '^MGMT=|^VM=|^STORAGE=')"

MGMT_INTERFACES="${MGMT:-eno1,eno2}"
VM_TRAFFIC_INTERFACES="${VM:-}"
STORAGE_INTERFACES="${STORAGE:-}"

IFS=',' read -ra MGMT_ARRAY <<< "$MGMT_INTERFACES"

# Netplan ethernets für mgmt interfaces (unconfigured, für bond)
MGMT_INTERFACES_NETPLAN=""
for iface in "${MGMT_ARRAY[@]}"; do
    iface=$(echo "$iface" | xargs)
    [[ -z "$iface" ]] && continue
    MGMT_INTERFACES_NETPLAN="${MGMT_INTERFACES_NETPLAN}      ${iface}:
        dhcp4: false
"
done

MGMT_BOND_INTERFACES=""
for iface in "${MGMT_ARRAY[@]}"; do
    iface=$(echo "$iface" | xargs)
    [[ -z "$iface" ]] && continue
    [[ -n "$MGMT_BOND_INTERFACES" ]] && MGMT_BOND_INTERFACES+=", "
    MGMT_BOND_INTERFACES+="\"${iface}\""
done

# Root-Passwort hashen (mkpasswd oder openssl)
if command -v mkpasswd >/dev/null 2>&1; then
    ROOT_PASSWORD_HASH=$(mkpasswd -m sha-512 "$ROOT_PASSWORD")
elif command -v python3 >/dev/null 2>&1; then
    ROOT_PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('${ROOT_PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))")
else
    ROOT_PASSWORD_HASH='$6$rounds=4096$saltsalt$placeholder'
fi

# Post-Install Skripte per HTTP in late-commands laden
LATE_COMMANDS_COPY_SCRIPTS=""
POST_INSTALL_DIR="${INSTALL_ROOT}/post-install"
PXE_IP="${PXE_SERVER_IP:-127.0.0.1}"
HTTP_POST_INSTALL="http://${PXE_IP}/assets/post-install"

if [[ -d "$POST_INSTALL_DIR" ]]; then
    LATE_COMMANDS_COPY_SCRIPTS=$'\n    - curtin in-target -- mkdir -p /root/post-install /root/config'
    for script in "$POST_INSTALL_DIR"/*.sh; do
        [[ -f "$script" ]] || continue
        basename_script=$(basename "$script")
        LATE_COMMANDS_COPY_SCRIPTS+=$'\n    - curtin shell -- wget -qO /target/root/post-install/'"${basename_script}"' '"${HTTP_POST_INSTALL}/${basename_script}"
        LATE_COMMANDS_COPY_SCRIPTS+=$'\n    - curtin in-target -- chmod +x /root/post-install/'"${basename_script}"
    done
fi

# Template ersetzen
OUTPUT_DIR="${OUTPUT_DIR:-${HTTP_ROOT}/hosts/${HOSTNAME}}"
mkdir -p "$OUTPUT_DIR"

user_data=$(cat "$TEMPLATE")
user_data="${user_data//@HOSTNAME@/$HOSTNAME}"
user_data="${user_data//@ROOT_PASSWORD_HASH@/$ROOT_PASSWORD_HASH}"
user_data="${user_data//@IP_ADDRESS@/$IP_ADDRESS}"
user_data="${user_data//@NETMASK@/$NETMASK}"
user_data="${user_data//@CIDR@/$CIDR}"
user_data="${user_data//@GATEWAY@/$GATEWAY}"
user_data="${user_data//@VLAN_ID@/$VLAN_ID}"
user_data="${user_data//@DNS_SERVERS@/$DNS_SERVERS}"
user_data="${user_data//@INTERFACE_PROFILE@/$INTERFACE_PROFILE}"
user_data="${user_data//@MGMT_INTERFACES@/$MGMT_INTERFACES}"
user_data="${user_data//@VM_TRAFFIC_INTERFACES@/$VM_TRAFFIC_INTERFACES}"
user_data="${user_data//@STORAGE_INTERFACES@/$STORAGE_INTERFACES}"
user_data="${user_data//@MGMT_BOND_MODE@/${MGMT_BOND_MODE:-802.3ad}}"
user_data="${user_data//@ISCSI_IQN_PREFIX@/${ISCSI_IQN_PREFIX:-iqn.2024-01.com.hpe}}"
user_data="${user_data//@DOMAIN@/${DOMAIN:-local}}"
user_data="${user_data//@MGMT_INTERFACES_NETPLAN@/$MGMT_INTERFACES_NETPLAN}"
user_data="${user_data//@MGMT_BOND_INTERFACES@/$MGMT_BOND_INTERFACES}"
user_data="${user_data//@LATE_COMMANDS_COPY_SCRIPTS@/$LATE_COMMANDS_COPY_SCRIPTS}"

echo "$user_data" > "${OUTPUT_DIR}/user-data"
echo "instance-id: ${HOSTNAME}" > "${OUTPUT_DIR}/meta-data"
echo "#cloud-config" > "${OUTPUT_DIR}/index.json"
echo '{"type":"text/cloud-config"}' >> "${OUTPUT_DIR}/index.json" 2>/dev/null || true

# Für nocloud-net
cat > "${OUTPUT_DIR}/config" << EOF
#cloud-config
EOF

echo "user-data generiert: ${OUTPUT_DIR}/user-data"
echo "OUTPUT_DIR=${OUTPUT_DIR}"
