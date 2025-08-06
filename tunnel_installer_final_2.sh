#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/Waterwall"

ROLE=""
IP_IRAN=""
IP_KHAREJ=""
PORTS=()
METHOD=""
USE_OBFS=false
USE_MUX=false
USE_TLS=false

MUX_CAPACITY=8
MUX_MODE=1
MUX_DURATION=60000

log() { echo -e "[+] $1"; }

if [[ "$1" == "--uninstall" ]]; then
    log "Uninstalling PacketTunnel..."
    systemctl stop packettunnel.service 2>/dev/null || true
    systemctl disable packettunnel.service 2>/dev/null || true
    systemctl stop packettunnel-restart.timer 2>/dev/null || true
    systemctl disable packettunnel-restart.timer 2>/dev/null || true
    pkill -f Waterwall 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f /etc/systemd/system/packettunnel-restart.service
    rm -f /etc/systemd/system/packettunnel-restart.timer
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reexec
    systemctl daemon-reload
    echo "✅ PacketTunnel fully removed."
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --ip-iran) IP_IRAN="$2"; shift 2 ;;
        --ip-kharej) IP_KHAREJ="$2"; shift 2 ;;
        --ports) shift; while [[ "$1" =~ ^[0-9]+$ ]]; do PORTS+=("$1"); shift || break; done ;;
        --method) METHOD="$2"; shift 2 ;;
        --obfs) USE_OBFS=true; shift ;;
        --mux) USE_MUX=true; shift ;;
        --tls) USE_TLS=true; shift ;;
        *) echo "❌ Unknown option: $1"; exit 1 ;;
    esac
done

# Normalize ROLE
ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]' | xargs)
if [[ -z "$ROLE" || -z "$IP_IRAN" || -z "$IP_KHAREJ" || -z "$METHOD" || ${#PORTS[@]} -eq 0 ]]; then
    echo "❌ Missing required arguments."
    echo "Usage: $0 --role iran|kharej --ip-iran A.B.C.D --ip-kharej X.Y.Z.W --ports 80 443 ... [--obfs] [--mux] [--tls]"
    exit 1
fi

# Determine Waterwall role: iran = Client, kharej = Server
if [[ "$ROLE" == "iran" ]]; then
    WATERWALL_ROLE="Client"
elif [[ "$ROLE" == "kharej" ]]; then
    WATERWALL_ROLE="Server"
else
    echo "❌ ROLE must be 'iran' or 'kharej'"
    exit 1
fi

log "Installing PacketTunnel for role: $ROLE ($WATERWALL_ROLE)"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Downloading Waterwall binary..."
curl -fsSL "$WATERWALL_URL" -o Waterwall
chmod +x Waterwall

log "Downloading core.json..."
curl -fsSL "$CORE_URL" -o core.json

log "Building config.json..."

# Start building config.json
cat > config.json <<EOF
{
  "name": "$ROLE",
  "nodes": [
    { "name": "tun", "type": "TunDevice", "settings": { "device-name": "wtun0", "device-ip": "10.10.0.1/24" }, "next": "srcip" },
    { "name": "srcip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "source-ip", "ipv4": "$([[ $ROLE == "iran" ]] && echo $IP_IRAN || echo $IP_KHAREJ)" }, "next": "dstip" },
    { "name": "dstip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "dest-ip", "ipv4": "$([[ $ROLE == "iran" ]] && echo $IP_KHAREJ || echo $IP_IRAN)" }, "next": "$([[ $METHOD == "half" ]] && echo manip || echo stream)" }
EOF

if [[ "$METHOD" == "half" ]]; then
cat >> config.json <<EOF
    ,
    { "name": "manip", "type": "IpManipulator", "settings": { "protoswap": 132, "tcp-flags": { "set": ["ack", "urg"], "unset": ["syn", "rst", "fin", "psh"] } }, "next": "dnsrc" },
    { "name": "dnsrc", "type": "IpOverrider", "settings": { "direction": "down", "mode": "source-ip", "ipv4": "10.10.0.2" }, "next": "dndst" },
    { "name": "dndst", "type": "IpOverrider", "settings": { "direction": "down", "mode": "dest-ip", "ipv4": "10.10.0.1" }, "next": "stream" }
EOF
fi

cat >> config.json <<EOF
    ,
    { "name": "stream", "type": "RawSocket", "settings": { "capture-filter-mode": "source-ip", "capture-ip": "$([[ $ROLE == "iran" ]] && echo $IP_KHAREJ || echo $IP_IRAN)" } }
EOF

base_port=30083
skip_port=30087

CHAIN_NODES=()

for i in "${!PORTS[@]}"; do
    port="${PORTS[$i]}"
    while [[ $base_port -eq $skip_port ]]; do ((base_port++)); done

    # Add TcpListener
    cat >> config.json <<EOF
    ,
    { "name": "input$((i+1))", "type": "TcpListener", "settings": { "address": "0.0.0.0", "port": $port, "nodelay": true }, "next": "chain$((i+1))" }
EOF

    chain="chain$((i+1))"

    # Mux
    if $USE_MUX; then
        cat >> config.json <<EOF
    ,
    { "name": "$chain", "type": "Mux${WATERWALL_ROLE}", "settings": {}, "next": "${chain}m" }
EOF
        chain="${chain}m"
        CHAIN_NODES+=("Mux")
    fi

    # Method (half, tcp, tls, etc.)
    method_pascal=$(echo "$METHOD" | sed 's/-//g' | sed 's/.*/\u&/')
    cat >> config.json <<EOF
    ,
    { "name": "$chain", "type": "${method_pascal}${WATERWALL_ROLE}", "settings": {}, "next": "${chain}o" }
EOF
    chain="${chain}o"
    CHAIN_NODES+=("$(echo "$METHOD" | tr '[:lower:]' '[:upper:]')")

    # Obfs
    if $USE_OBFS; then
        cat >> config.json <<EOF
    ,
    { "name": "$chain", "type": "Obfuscator${WATERWALL_ROLE}", "settings": {"method": "xor", "xor_key": "123"}, "next": "${chain}t" }
EOF
        chain="${chain}t"
        CHAIN_NODES+=("Obfs")
    fi

    # TLS
    if $USE_TLS && [[ "$METHOD" != "tls" ]]; then
        cat >> config.json <<EOF
    ,
    { "name": "$chain", "type": "Tls${WATERWALL_ROLE}", "settings": {}, "next": "${chain}t2" }
EOF
        chain="${chain}t2"
        CHAIN_NODES+=("TLS")
    fi

    # TcpConnector
    local connector_ip connector_port
    if [[ "$ROLE" == "iran" ]]; then
        connector_ip="10.10.0.2"   # Connect to kharej's wtun0
        connector_port="$base_port"
    else
        connector_ip="127.0.0.1"   # Connect to local service
        connector_port="$port"
    fi

    cat >> config.json <<EOF
    ,
    { "name": "$chain", "type": "TcpConnector", "settings": { "nodelay": true, "address": "$connector_ip", "port": $connector_port } }
EOF

    ((base_port++))
done

cat >> config.json <<EOF
  ]
}
EOF

log "Node chain order: ${CHAIN_NODES[*]}"

# poststart.sh
cat > "$INSTALL_DIR/poststart.sh" <<'EOF'
#!/bin/bash
for i in {1..10}; do ip link show wtun0 && break; sleep 1; done
ip link set dev eth0 mtu 1420 || true
ip link set dev wtun0 mtu 1420 || true
EOF
chmod +x "$INSTALL_DIR/poststart.sh"

# Service file
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PacketTunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/bash -c "ip link delete wtun0 || true"
ExecStart=$INSTALL_DIR/Waterwall -c $INSTALL_DIR/config.json
ExecStartPost=$INSTALL_DIR/poststart.sh
ExecStopPost=/bin/bash -c "ip link delete wtun0 || true"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable packettunnel.service
systemctl restart packettunnel.service

# Restart timer
cat > /etc/systemd/system/packettunnel-restart.service <<'EOF'
[Unit]
Description=Restart PacketTunnel every 10 mins

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart packettunnel.service
EOF

cat > /etc/systemd/system/packettunnel-restart.timer <<EOF
[Unit]
Description=Timer for restarting packettunnel every 10 mins

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

systemctl enable --now packettunnel-restart.timer

log "✅ PacketTunnel installed and running."
log "💡 Role: $ROLE ($WATERWALL_ROLE)"
log "💡 Config: $INSTALL_DIR/config.json"
