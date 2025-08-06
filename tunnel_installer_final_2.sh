#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
# ✅ حذف اسپیس اضافه در انتهای URL
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

log() { echo -e "[+] $1"; }

if [[ "$1" == "--uninstall" ]]; then
    systemctl stop packettunnel.service 2>/dev/null || true
    systemctl disable packettunnel.service 2>/dev/null || true
    systemctl stop packettunnel-restart.timer 2>/dev/null || true
    systemctl disable packettunnel-restart.timer 2>/dev/null || true
    pkill -f Waterwall 2>/dev/null || true
    rm -f /etc/systemd/system/packettunnel.service
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
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Normalize ROLE
ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]' | xargs)

if [[ -z "$ROLE" || -z "$IP_IRAN" || -z "$IP_KHAREJ" || -z "$METHOD" || ${#PORTS[@]} -eq 0 ]]; then
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

log "Building config.json..."

# Determine client/server role
if [[ "$ROLE" == "iran" ]]; then
    NODE_ROLE="Client"
else
    NODE_ROLE="Server"
fi

CHAIN_NODES=()
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

for i in "${!PORTS[@]}"; do
    port="${PORTS[$i]}"
    while [[ $base_port -eq $skip_port ]]; do ((base_port++)); done

    echo "    , { \"name\": \"input$((i+1))\", \"type\": \"TcpListener\", \"settings\": { \"address\": \"0.0.0.0\", \"port\": ${PORTS[$i]}, \"nodelay\": true }, \"next\": \"chain$((i+1))\" }" >> config.json
    chain="chain$((i+1))"

    if $USE_MUX; then
        # ✅ اصلاح اصلی: اضافه کردن concurrency_mode: 1
        echo "    , { \"name\": \"$chain\", \"type\": \"Mux${NODE_ROLE}\", \"settings\": { \"concurrency_mode\": 1 }, \"next\": \"${chain}m\" }" >> config.json
        chain="${chain}m"
        CHAIN_NODES+=("Mux")
    fi

    if [[ "$METHOD" == "half" ]]; then
        type="HalfDuplex${NODE_ROLE}"
    else
        type_name=$(echo "$METHOD" | sed 's/-//g')
        method_pascal=$(tr '[:lower:]' '[:upper:]' <<< ${type_name:0:1})${type_name:1}
        type="${method_pascal}${NODE_ROLE}"
    fi

    echo "    , { \"name\": \"$chain\", \"type\": \"$type\", \"settings\": {}, \"next\": \"${chain}o\" }" >> config.json
    chain="${chain}o"
    CHAIN_NODES+=("$METHOD")

    if $USE_OBFS; then
        echo "    , { \"name\": \"$chain\", \"type\": \"Obfuscator${NODE_ROLE}\", \"settings\": {\"method\": \"xor\", \"xor_key\": \"123\"}, \"next\": \"${chain}t\" }" >> config.json
        chain="${chain}t"
        CHAIN_NODES+=("Obfs")
    fi

    if $USE_TLS && [[ "$METHOD" != "tls" ]]; then
        echo "    , { \"name\": \"$chain\", \"type\": \"Tls${NODE_ROLE}\", \"settings\": {}, \"next\": \"${chain}t2\" }" >> config.json
        chain="${chain}t2"
        CHAIN_NODES+=("TLS")
    fi

    echo "    , { \"name\": \"$chain\", \"type\": \"TcpConnector\", \"settings\": { \"nodelay\": true, \"address\": \"$([[ $ROLE == \"iran\" ]] && echo 10.10.0.2 || echo 127.0.0.1)\", \"port\": $([[ $ROLE == \"iran\" ]] && echo $base_port || echo $port) } }" >> config.json
    ((base_port++))
done

# فرمت‌بندی درست JSON
sed -i '2s/^/  /;3,$s/^/    /' config.json
echo "  ]
}" >> config.json

log "Node chain order: ${CHAIN_NODES[*]}"

# ✅ اسکریپت پس از شروع: تضمین ایجاد tun و تنظیم mtu
cat > "$INSTALL_DIR/poststart.sh" <<EOF
#!/bin/bash
# اطمینان از اینکه wtun0 ساخته شده
for i in {1..10}; do
    ip link show wtun0 > /dev/null 2>&1 && break
    sleep 1
done

# تنظیم MTU (اختیاری اما توصیه‌شده)
ip link set dev eth0 mtu 1420 || true
ip link set dev wtun0 mtu 1420 || true

# اگر tun دستگاه وجود نداشت، خطا می‌دهد
if ! ip link show wtun0 > /dev/null 2>&1; then
    echo "ERROR: wtun0 device was not created by Waterwall!" >&2
    exit 1
fi
EOF
chmod +x "$INSTALL_DIR/poststart.sh"

# ✅ تنظیم سرویس سیستمی
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PacketTunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
# حذف دستگاه قبلی اگر وجود داشت
ExecStartPre=/bin/bash -c "ip link delete wtun0 || true"
# اجرای Waterwall با مشخص کردن فایل پیکربندی
ExecStart=$INSTALL_DIR/Waterwall -c $INSTALL_DIR/config.json
# اجرای پس‌پردازش
ExecStartPost=$INSTALL_DIR/poststart.sh
# پاک کردن دستگاه در هنگام توقف
ExecStopPost=/bin/bash -c "ip link delete wtun0 || true"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# بارگذاری مجدد سرویس‌ها
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable packettunnel.service
systemctl restart packettunnel.service

# ✅ تنظیم تایمر ریستارت (هر ۱۰ دقیقه)
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

systemctl daemon-reload
systemctl enable --now packettunnel-restart.timer

log "✅ PacketTunnel installed and running."
