#!/bin/bash

set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/NIKA1371/packet-tcp-new/main/Waterwall"

function log() {
    echo "[+] $1"
}

function uninstall() {
    log "Stopping and disabling systemd service..."
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
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_iran"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 132,
                "tcp-flags": {
                    "set": ["ack"],
                    "unset": ["syn", "rst", "fin", "psh", "urg"]
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
            "next": "rd"
        },
        {
            "name": "rd",
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
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_iran"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 132,
                "tcp-flags": {
                    "set": ["ack"],
                    "unset": ["syn", "rst", "fin", "psh", "urg"]
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
            "next": "rd"
        },
        {
            "name": "rd",
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

function install_service() {
    log "Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=packet Tunnel Service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/Waterwall
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    log "Reloading systemd and enabling service..."
    systemctl daemon-reexec
    systemctl enable packettunnel.service
    systemctl restart packettunnel.service
}

function install_menu() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    log "Downloading Waterwall binary..."
    curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/Waterwall -o "$INSTALL_DIR/Waterwall"
chmod +x "$INSTALL_DIR/Waterwall"
    chmod +x Waterwall

    log "Downloading core.json..."
    curl -fsSL "$CORE_URL" -o core.json

    read -rp "Is this server 'iran' or 'kharej'? " role
    read -rp "Enter Iran server public IP: " ip_iran
    read -rp "Enter Kharej server public IP: " ip_kharej

    if [[ "$role" == "iran" ]]; then
        prompt_ports
        generate_iran_config "$ip_iran" "$ip_kharej"
    elif [[ "$role" == "kharej" ]]; then
        generate_kharej_config "$ip_kharej" "$ip_iran"
    else
        echo "Invalid role. Must be 'iran' or 'kharej'."
        exit 1
    fi

    install_service
    log "✅ Tunnel setup complete. Service is running."
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
