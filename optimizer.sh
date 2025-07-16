#!/bin/bash
#
# optimize.sh
# Final script to apply simultaneous throughput and low-latency tuning on a Linux server:
#
# • Set sysctl (only net.core.default_qdisc + BBR + Fast Open + buffers + TIME-WAIT + Keepalive)
# • Load tcp_bbr module and register it for boot
# • Set MTU of default interface to 1420 and add auto /24 route
# • Disable NIC offloads (GRO, GSO, TSO, LRO) for lowest latency
# • Reduce interrupt coalescing (generate interrupt for each packet)
# • Assign IRQ affinity to a single CPU core for greater stability
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ArshiaParvane/ArshiaParvane-optimize/main/optimize.sh | sudo bash
#
# Notes:
#   • If the server doesn't support `cake`, it will automatically fall back to `fq_codel`.
#   • To revert MTU and route changes, manually set MTU back to 1500 and remove the /24 route.
#

set -o errexit
set -o nounset
set -o pipefail

LOGFILE="/var/log/optimize.log"

die() {
  echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo -e "\e[32m[INFO]\e[0m $1" | tee -a "$LOGFILE"
}

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

log "Starting network tuning for low-latency and throughput..."

# -----------------------------------------------------------
# 1. Apply sysctl settings for net.core.default_qdisc and others
# -----------------------------------------------------------
declare -A sysctl_opts=(
  # Queueing: prefer cake, fallback to fq_codel if unsupported
  ["net.core.default_qdisc"]="cake"

  # Congestion Control
  ["net.ipv4.tcp_congestion_control"]="bbr"

  # TCP Fast Open
  ["net.ipv4.tcp_fastopen"]="3"

  # MTU Probing
  ["net.ipv4.tcp_mtu_probing"]="1"

  # Window Scaling
  ["net.ipv4.tcp_window_scaling"]="1"

  # Backlog / SYN Queue
  ["net.core.somaxconn"]="1024"
  ["net.ipv4.tcp_max_syn_backlog"]="2048"
  ["net.core.netdev_max_backlog"]="500000"

  # Buffer sizes
  ["net.core.rmem_default"]="262144"
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_default"]="262144"
  ["net.core.wmem_max"]="134217728"
  ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
  ["net.ipv4.tcp_wmem"]="4096 65536 67108864"

  # TIME-WAIT reuse
  ["net.ipv4.tcp_tw_reuse"]="1"
  # ["net.ipv4.tcp_tw_recycle"]="1"   # Disabled to avoid NAT issues

  # FIN_TIMEOUT and Keepalive
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_keepalive_time"]="300"
  ["net.ipv4.tcp_keepalive_intvl"]="30"
  ["net.ipv4.tcp_keepalive_probes"]="5"

  # TCP No Metrics Save
  ["net.ipv4.tcp_no_metrics_save"]="1"
)

log "Applying sysctl settings..."
for key in "${!sysctl_opts[@]}"; do
  value="${sysctl_opts[$key]}"

  if sysctl -w "$key=$value" >/dev/null 2>&1; then
    grep -qxF "$key = $value" /etc/sysctl.conf || echo "$key = $value" >> /etc/sysctl.conf
    log "Applied and saved: $key = $value"
  else
    if [[ "$key" == "net.core.default_qdisc" ]]; then
      fallback="fq_codel"
      sysctl -w "$key=$fallback" >/dev/null 2>&1 || die "Cannot set $key to $fallback"
      grep -qxF "$key = $fallback" /etc/sysctl.conf || echo "$key = $fallback" >> /etc/sysctl.conf
      log "Fallback applied for $key: $fallback"
    else
      die "Failed to apply sysctl: $key=$value"
    fi
  fi
done

sysctl -p >/dev/null 2>&1 || die "Failed to reload sysctl"
log "All sysctl settings applied and saved."

# -----------------------------------------------------------
# 2. Load tcp_bbr module
# -----------------------------------------------------------
log "Loading tcp_bbr module..."
if ! lsmod | grep -q '^tcp_bbr'; then
  modprobe tcp_bbr || die "Failed to load tcp_bbr module"
  echo "tcp_bbr" >/etc/modules-load.d/bbr.conf
  log "tcp_bbr loaded and set for boot."
else
  log "tcp_bbr module was already loaded."
fi

# -----------------------------------------------------------
# 3. Get default interface and auto /24 CIDR
# -----------------------------------------------------------
get_iface_and_cidr() {
  local IFACE
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}') || die "Cannot detect default interface."
  local IP_ADDR
  IP_ADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1) || die "Cannot read IP for interface $IFACE."
  local BASE
  BASE=$(echo "$IP_ADDR" | cut -d. -f1-3)
  local CIDR="${BASE}.0/24"
  echo "$IFACE" "$CIDR"
}

read IFACE CIDR < <(get_iface_and_cidr)
log "Default interface: $IFACE   Auto CIDR: $CIDR"

# -----------------------------------------------------------
# 4. Set MTU to 1420 and add auto route
# -----------------------------------------------------------
current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
if [ "$current_mtu" != "1420" ]; then
  ip link set dev "$IFACE" mtu 1420 || die "Failed to set MTU to 1420 for $IFACE"
  log "MTU set to 1420 for $IFACE"
else
  log "MTU for $IFACE already set to 1420."
fi

if ! ip route show | grep -qw "$CIDR"; then
  ip route add "$CIDR" dev "$IFACE" || die "Failed to add route $CIDR to $IFACE"
  log "Route $CIDR added to interface $IFACE."
else
  log "Route $CIDR already exists."
fi

# -----------------------------------------------------------
# 5. Disable NIC offloads (GRO, GSO, TSO, LRO)
# -----------------------------------------------------------
log "Disabling NIC offloads on $IFACE..."
ethtool -K "$IFACE" gro off gso off tso off lro off \
  && log "Offloads disabled." \
  || log "Warning: NIC offloads not supported or already disabled."

# -----------------------------------------------------------
# 6. Reduce interrupt coalescing (one interrupt per packet)
# -----------------------------------------------------------
log "Reducing interrupt coalescing on $IFACE..."
ethtool -C "$IFACE" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 \
  && log "Interrupt coalescing configured for 1 interrupt per packet." \
  || log "Warning: coalescing not supported or not configurable."

# -----------------------------------------------------------
# 7. Assign IRQ affinity to CPU core #1
# -----------------------------------------------------------
log "Assigning IRQ affinity for $IFACE to CPU core #1..."
for irq in $(grep -R "$IFACE" /proc/interrupts | awk -F: '{print $1}'); do
  echo 2 > /proc/irq/"$irq"/smp_affinity \
    && log "Assigned IRQ $irq to CPU core #1." \
    || log "Warning: Failed to assign IRQ $irq to core #1."
done

# -----------------------------------------------------------
# 8. Final summary and recommendations
# -----------------------------------------------------------
log "All low-latency and throughput settings have been applied."
log "To verify:"
log "  • TCP Congestion Control:  sysctl net.ipv4.tcp_congestion_control"
log "  • MTU:                     ip link show $IFACE"
log "  • Route /24:               ip route show | grep \"$CIDR\""
log "  • Offloads:                ethtool -k $IFACE | grep -E 'gso|gro|tso|lro'"
log "  • Coalescing:              ethtool -c $IFACE"
log "  • IRQ affinity:            grep \"$IFACE\" /proc/interrupts"

echo -e "\n\e[34m>>> Settings applied. Now test with ping and iperf3.\e[0m\n"
exit 0

