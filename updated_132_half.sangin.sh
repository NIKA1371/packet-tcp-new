#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/Waterwall"

log() {
    echo -e "[+] $1"
}

# حذف نصب
if [[ "$1" == "--uninstall" ]]; then
    echo "[*] Stopping PacketTunnel service..."
    systemctl stop packettunnel.service 2>/dev/null
    systemctl disable packettunnel.service 2>/dev/null
    systemctl stop packettunnel-restart.timer 2>/dev/null
    systemctl disable packettunnel-restart.timer 2>/dev/null

    echo "[*] Killing any running Waterwall..."
    pkill -f Waterwall 2>/dev/null

    echo "[*] Removing service and timer files..."
    rm -f /etc/systemd/system/packettunnel.service
    rm -f /etc/systemd/system/packettunnel-restart.service
    rm -f /etc/systemd/system/packettunnel-restart.timer

    echo "[*] Removing installation directory..."
    rm -rf /root/packettunnel

    echo "[*] Reloading systemd..."
    systemctl daemon-reexec
    systemctl daemon-reload

    echo "✅ PacketTunnel fully removed."
    exit 0
fi

# بررسی نبود آرگومان
if [[ $# -eq 0 ]]; then
    echo "❌ No arguments provided."
    echo "Usage:"
    echo "  --role iran|kharej --ip-iran x.x.x.x --ip-kharej x.x.x.x --ports <list>"
    echo "  --uninstall"
    exit 1
fi

# پارس آرگومان‌ها
ROLE=""
IP_IRAN=""
IP_KHAREJ=""
PORTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --ip-iran) IP_IRAN="$2"; shift 2 ;;
        --ip-kharej) IP_KHAREJ="$2"; shift 2 ;;
        --ports)
            shift
            while [[ "$1" =~ ^[0-9]+$ ]]; do
                PORTS+=("$1")
                shift || break
            done
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ROLE" || -z "$IP_IRAN" || -z "$IP_KHAREJ" ]]; then
    echo "❌ Missing required arguments"
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Downloading Waterwall..."
curl -fsSL "$WATERWALL_URL" -o Waterwall
chmod +x Waterwall

log "Downloading core.json..."
curl -fsSL "$CORE_URL" -o core.json

# تولید config سمت ایران
if [[ "$ROLE" == "iran" ]]; then
    cat > "$INSTALL_DIR/config.json" <<EOF
{
  "name": "iran",
  "nodes": [
    { "name": "tun", "type": "TunDevice", "settings": { "device-name": "wtun0", "device-ip": "10.10.0.1/24" }, "next": "srcip" },
    { "name": "srcip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "source-ip", "ipv4": "$IP_IRAN" }, "next": "dstip" },
    { "name": "dstip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "dest-ip", "ipv4": "$IP_KHAREJ" }, "next": "manip" },
    { "name": "manip", "type": "IpManipulator", "settings": { "protoswap": 253, "tcp-flags": { "set": ["ack", "rst"], "unset": ["syn", "urg", "fin", "psh"] } }, "next": "dnsrc" },
    { "name": "dnsrc", "type": "IpOverrider", "settings": { "direction": "down", "mode": "source-ip", "ipv4": "10.10.0.2" }, "next": "dndst" },
    { "name": "dndst", "type": "IpOverrider", "settings": { "direction": "down", "mode": "dest-ip", "ipv4": "10.10.0.1" }, "next": "stream" },
    { "name": "stream", "type": "RawSocket", "settings": { "capture-filter-mode": "source-ip", "capture-ip": "$IP_KHAREJ" } },
EOF

    base_port=30083
    skip_port=30087
    for i in "${!PORTS[@]}"; do
        while [[ $base_port -eq $skip_port ]]; do ((base_port++)); done
        echo "    { \"name\": \"input$((i+1))\", \"type\": \"TcpListener\", \"settings\": { \"address\": \"0.0.0.0\", \"port\": ${PORTS[$i]}, \"nodelay\": true }, \"next\": \"hd$((i+1))\" }," >> config.json
        echo "    { \"name\": \"hd$((i+1))\", \"type\": \"HalfDuplexClient\", \"settings\": {}, \"next\": \"out$((i+1))\" }," >> config.json
        echo "    { \"name\": \"out$((i+1))\", \"type\": \"TcpConnector\", \"settings\": { \"nodelay\": true, \"address\": \"10.10.0.2\", \"port\": $base_port } }," >> config.json
        echo "    // ${PORTS[$i]} → $base_port"  # برای خوانایی نگاشت
        ((base_port++))
    done
    sed -i '$ s/,$//' config.json
    echo "  ]
}" >> config.json
fi

# تولید config سمت خارج
if [[ "$ROLE" == "kharej" ]]; then
    cat > "$INSTALL_DIR/config.json" <<EOF
{
  "name": "kharej",
  "nodes": [
    { "name": "tun", "type": "TunDevice", "settings": { "device-name": "wtun0", "device-ip": "10.10.0.1/24" }, "next": "srcip" },
    { "name": "srcip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "source-ip", "ipv4": "$IP_KHAREJ" }, "next": "dstip" },
    { "name": "dstip", "type": "IpOverrider", "settings": { "direction": "up", "mode": "dest-ip", "ipv4": "$IP_IRAN" }, "next": "manip" },
    { "name": "manip", "type": "IpManipulator", "settings": { "protoswap": 253, "tcp-flags": { "set": ["ack", "rst"], "unset": ["syn", "urg", "fin", "psh"] } }, "next": "dnsrc" },
    { "name": "dnsrc", "type": "IpOverrider", "settings": { "direction": "down", "mode": "source-ip", "ipv4": "10.10.0.2" }, "next": "dndst" },
    { "name": "dndst", "type": "IpOverrider", "settings": { "direction": "down", "mode": "dest-ip", "ipv4": "10.10.0.1" }, "next": "stream" },
    { "name": "stream", "type": "RawSocket", "settings": { "capture-filter-mode": "source-ip", "capture-ip": "$IP_IRAN" } },
EOF

    base_port=30083
    skip_port=30087
    for i in "${!PORTS[@]}"; do
        while [[ $base_port -eq $skip_port ]]; do ((base_port++)); done
        echo "    { \"name\": \"input$((i+1))\", \"type\": \"TcpListener\", \"settings\": { \"address\": \"0.0.0.0\", \"port\": $base_port, \"nodelay\": true }, \"next\": \"hd$((i+1))\" }," >> config.json
        echo "    { \"name\": \"hd$((i+1))\", \"type\": \"HalfDuplexServer\", \"settings\": {}, \"next\": \"out$((i+1))\" }," >> config.json
        echo "    { \"name\": \"out$((i+1))\", \"type\": \"TcpConnector\", \"settings\": { \"nodelay\": true, \"address\": \"127.0.0.1\", \"port\": ${PORTS[$i]} } }," >> config.json
        echo "    // $base_port → ${PORTS[$i]}"  # نگاشت برعکس
        ((base_port++))
    done
    sed -i '$ s/,$//' config.json
    echo "  ]
}" >> config.json
fi

# راه‌اندازی systemd
log "Creating poststart.sh..."
cat > poststart.sh <<EOF
#!/bin/bash
for i in {1..10}; do ip link show wtun0 && break; sleep 1; done
ip link set dev eth0 mtu 1420 || true
ip link set dev wtun0 mtu 1420 || true
EOF
chmod +x poststart.sh

log "Creating systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PacketTunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/bash -c "ip link delete wtun0 || true"
ExecStart=$INSTALL_DIR/Waterwall
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

# تایمر ری‌استارت
log "Creating 10-minute restart timer..."
cat > /etc/systemd/system/packettunnel-restart.service <<EOF
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
