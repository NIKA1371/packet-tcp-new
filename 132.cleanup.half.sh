#!/bin/bash

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
