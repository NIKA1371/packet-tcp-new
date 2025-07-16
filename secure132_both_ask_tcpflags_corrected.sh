#!/bin/bash


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



set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/mahdipatriot/PacketTunnel/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/mahdipatriot/PacketTunnel/main/Waterwall"

function log() {
    echo "[+] $1"
}

function uninstall() {
    log "Stopping and disabling systemd service..."
    pkill -f Waterwall || true  # Kill running Waterwall if exists
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
    log "Enter ports to forward (e.g. 443 8443 80), type 'done' to finish:"
    while true; do
        read -rp "Port: " p
        [[ "$p" == "done" ]] && break
        [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p") || echo "Invalid port number."
    done
}

function generate_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "flowA"
        },
        {
            "name": "flowA",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_iran"
            },
            "next": "flowB"
        },
        {
            "name": "flowB",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "stage2"
        },
        {
            "name": "stage2",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 132,
                "tcp-flags": {
                    "set": ${FLAGS_SET},
                    "unset": ${FLAGS_UNSET}
                },
            },
            "next": "flowC"
        },
        {
            "name": "flowC",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "10.10.0.2"
            },
            "next": "flowD"
        },
        {
            "name": "flowD",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "streamer"
        },
        {
            "name": "streamer",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_kharej"
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

    echo "    ]" >> "$INSTALL_DIR/config.json"
    echo "}" >> "$INSTALL_DIR/config.json"
}

function generate_kharej_config() {
    local ip_kharej="$1"
    local ip_iran="$2"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "flowA"
        },
        {
            "name": "flowA",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "flowB"
        },
        {
            "name": "flowB",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_iran"
            },
            "next": "stage2"
        },
        {
            "name": "stage2",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 132,
                "tcp-flags": {
                    "set": ${FLAGS_SET},
                    "unset": ${FLAGS_UNSET}
                },
            },
            "next": "flowC"
        },
        {
            "name": "flowC",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "10.10.0.2"
            },
            "next": "flowD"
        },
        {
            "name": "flowD",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "streamer"
        },
        {
            "name": "streamer",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_iran"
            }
        }
    ]
}
EOF
}
    log "Killing any existing Waterwall instance..."
    pkill -f Waterwall || true
    sleep 1
    fuser -k 443/tcp || true

    install_service() {
    log "Creating post-start script for MTU configuration..."

    log "Creating post-start script for MTU configuration..."
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
    pkill -f Waterwall || true  # kill any running Waterwall process
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=packet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/bash -c "ip link delete wtun0 || true"
ExecStart=$INSTALL_DIR/Waterwall
ExecStartPost=/root/packettunnel/poststart.sh
ExecStopPost=/bin/bash -c "ip link delete wtun0 || true"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF



    log "Reloading systemd and enabling service..."
    systemctl daemon-reexec
    systemctl enable packettunnel.service
    systemctl restart packettunnel.service

    log "Creating systemd timer for 10-minute restarts..."
    cat > /etc/systemd/system/packettunnel-restart.service <<EOF
[Unit]
Description=Restart packettunnel service every 10 minutes

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart packettunnel.service
EOF

    cat > /etc/systemd/system/packettunnel-restart.timer <<EOF
[Unit]
Description=Timer for restarting packettunnel every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now packettunnel-restart.timer
    log "✅ Timer for 10-minute restart enabled."

}

function install_menu() {
    log "Cleaning crontab to prevent conflicts..."
    crontab -l 2>/dev/null | grep -vE 'restart_waterwall|mtu 1420' | crontab -

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    log "Downloading Waterwall binary..."
    curl -fsSL "$WATERWALL_URL" -o "$INSTALL_DIR/Waterwall"
    chmod +x "$INSTALL_DIR/Waterwall"
    ln -sf "$INSTALL_DIR/Waterwall" /usr/local/bin/wtunnel

    log "Downloading core.json..."
    curl -fsSL "$CORE_URL" -o core.json

    read -rp "Is this server 'iran' or 'kharej'? " role

    function validate_ip() {
        [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            echo "Invalid IP format: $1"
            exit 1
        }
    }

    read -rp "Enter Iran server public IP: " ip_iran
    validate_ip "$ip_iran"
    read -rp "Enter Kharej server public IP: " ip_kharej
    validate_ip "$ip_kharej"

    if [[ "$role" == "iran" ]]; then
        choose_tcp_flag_mode
        prompt_ports
        generate_iran_config "$ip_iran" "$ip_kharej"
    elif [[ "$role" == "kharej" ]]; then
        echo "[⚠️] Choose the SAME TCP Flag mode used on the IRAN server!"
        choose_tcp_flag_mode
        generate_kharej_config "$ip_kharej" "$ip_iran"
    else
        echo "Invalid role. Must be 'iran' or 'kharej'."
        exit 1
    fi

    install_service

    log "Killing any existing Waterwall instance..."
    pkill -f Waterwall || true
    sleep 1
    fuser -k 443/tcp || true

    install_service
    log "✅ Tunnel setup complete. Service is running."
}

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