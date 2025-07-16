#!/bin/bash

set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/mahdipatriot/PacketTunnel/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/mahdipatriot/PacketTunnel/main/Waterwall"

function log() {
    echo -e "\e[32m[+] $1\e[0m"
}

function validate_ip() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Invalid IP format: $1"
        exit 1
    }
}

function uninstall() {
    log "Stopping and disabling systemd service..."
    pkill -f Waterwall || true
    systemctl stop packettunnel.service || true
    systemctl disable packettunnel.service || true

    log "Removing files..."
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"

    log "Reloading systemd..."
    systemctl daemon-reexec
    log "✅ Uninstall complete."
    exit 0
}

function prompt_ports() {
    ports=()
    log "Enter up to 8 ports to forward (e.g. 443 8443 80), type 'done' to finish:"
    while [ ${#ports[@]} -lt 8 ]; do
        read -rp "Port: " p
        [[ "$p" == "done" ]] && break
        [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p") || echo "Invalid port number."
    done
}

function choose_tcp_flag_mode() {
    echo "Choose TCP flag mode:"
    echo "1) Minimal (only ACK)"
    echo "2) Disguise (ACK + URG)"
    read -rp "Choice [1-2]: " choice
    if [[ "$choice" == "2" ]]; then
        FLAGS_SET='["ack", "urg"]'
        FLAGS_UNSET='["syn", "rst", "fin", "psh"]'
    else
        FLAGS_SET='["ack"]'
        FLAGS_UNSET='["syn", "rst", "fin", "psh", "urg"]'
    fi
}

function generate_config() {
    local ip_this="$1"
    local ip_other="$2"
    local role="$3"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "$role",
    "nodes": [
        {
            "name": "tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_this"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_other"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 132,
                "tcp-flags": {
                    "set": $FLAGS_SET,
                    "unset": $FLAGS_UNSET
                }
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "10.10.0.2"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "raw"
        },
        {
            "name": "raw",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_other"
            }
        }
EOF

    for i in "${!ports[@]}"; do
        cat >> "$INSTALL_DIR/config.json" <<EOF
,
        {
            "name": "input$((i+1))",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${ports[i]},
                "nodelay": true
            },
            "next": "output$((i+1))"
        },
        {
            "name": "output$((i+1))",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "10.10.0.2",
                "port": ${ports[i]}
            }
        }
EOF
    done

    echo "    ]
}" >> "$INSTALL_DIR/config.json"
}

function install_service() {
    log "Creating post-start script..."
    cat > "$INSTALL_DIR/poststart.sh" <<EOL
#!/bin/bash
for i in {1..10}; do
  ip link show wtun0 && break
  sleep 1
done
ip link set dev eth0 mtu 1420 || true
ip link set dev wtun0 mtu 1420 || true
EOL
    chmod +x "$INSTALL_DIR/poststart.sh"

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

    log "Setting up systemd timer..."
    cat > /etc/systemd/system/packettunnel-restart.service <<EOF
[Unit]
Description=Restart PacketTunnel every 10 minutes

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart packettunnel.service
EOF

    cat > /etc/systemd/system/packettunnel-restart.timer <<EOF
[Unit]
Description=Timer for PacketTunnel restart

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reexec
    systemctl enable --now packettunnel-restart.timer
}

function install_menu() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    log "Downloading Waterwall binary..."
    curl -fsSL "$WATERWALL_URL" -o Waterwall
    chmod +x Waterwall

    curl -fsSL "$CORE_URL" -o core.json

    read -rp "Is this server 'iran' or 'kharej'? " role
    read -rp "Enter Iran server public IP: " ip_iran
    validate_ip "$ip_iran"
    read -rp "Enter Kharej server public IP: " ip_kharej
    validate_ip "$ip_kharej"

    prompt_ports
    choose_tcp_flag_mode

    if [[ "$role" == "iran" ]]; then
        generate_config "$ip_iran" "$ip_kharej" "$role"
    else
        generate_config "$ip_kharej" "$ip_iran" "$role"
    fi

    install_service
    log "✅ Tunnel setup complete."
}

# MAIN MENU
echo "PacketTunnel Setup"
echo "=================="
echo "1) Install"
echo "2) Uninstall"
read -rp "Choose an option [1-2]: " choice

case "$choice" in
    1) install_menu ;;
    2) uninstall ;;
    *) echo "Invalid option." ;;
esac
