#!/bin/bash
# ct-hotfix-docker.sh — Fix intermittent Docker startup failures on existing appliances
#
# Addresses three root causes of the boot-time ZONE_CONFLICT / deprecated kernel
# module warnings reported on Call Telemetry appliances running AlmaLinux 9:
#
#   1. Docker using iptables-nft backend → loads deprecated nft_compat/ip_set modules
#   2. NetworkManager auto-managing docker0/br-* bridges → races Docker on boot
#   3. Docker starting before firewalld finishes initialising zones → ZONE_CONFLICT
#
# References:
#   https://github.com/moby/moby/issues/41609
#   https://github.com/firewalld/firewalld/issues/195
#
# Usage:
#   sudo bash ct-hotfix-docker.sh
#
# A reboot is required for all changes to take effect.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo bash ct-hotfix-docker.sh)" >&2
  exit 1
fi

echo "======================================================================"
echo " Call Telemetry — Docker Startup Hotfix"
echo "======================================================================"
echo ""

# ── Fix 1: Switch Docker to native nftables firewall backend ──────────────
# Docker 29.0+ supports nftables natively. This eliminates the deprecated
# nft_compat and ip_set kernel modules that the default iptables-nft backend
# loads, and stops Docker from negotiating firewalld zones entirely —
# eliminating ZONE_CONFLICT at the source.
echo "[1/4] Configuring Docker nftables firewall backend..."

docker_major=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)

mkdir -p /etc/docker
if [ "${docker_major:-0}" -ge 29 ]; then
  if [[ -f /etc/docker/daemon.json ]] && command -v jq &>/dev/null; then
    jq '. + {"firewall-backend": "nftables"}' /etc/docker/daemon.json > /tmp/daemon.json.tmp \
      && mv /tmp/daemon.json.tmp /etc/docker/daemon.json
    echo "      Merged into existing: /etc/docker/daemon.json"
  else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "firewall-backend": "nftables"
}
EOF
    echo "      Written: /etc/docker/daemon.json"
  fi
else
  echo "      [WARN] Docker ${docker_major:-unknown} < 29 — skipping nftables backend (requires Docker 29+)"
fi

# ── Fix 2: Enable IP forwarding (required by nftables backend) ────────────
# The nftables backend does NOT enable IP forwarding automatically (unlike the
# default iptables backend). Without this, Docker logs an error and may fall
# back to iptables on the next restart.
echo "[2/4] Enabling IP forwarding for nftables backend..."

cat > /etc/sysctl.d/99-docker-ipforward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-docker-ipforward.conf
echo "      Written: /etc/sysctl.d/99-docker-ipforward.conf"

# ── Fix 3: Stop NetworkManager managing Docker bridge interfaces ───────────
# NM auto-generates /run/ profiles with autoconnect=yes for any kernel bridge
# it sees (docker0, br-*). On every boot this races Docker for bridge
# ownership, causing the intermittent ZONE_CONFLICT failures.
echo "[3/4] Configuring NetworkManager to ignore Docker bridges..."

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/docker-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:docker*;interface-name:br-*
EOF
echo "      Written: /etc/NetworkManager/conf.d/docker-unmanaged.conf"

# Delete any existing NM-managed profiles for docker bridges so they don't
# linger until the next reboot.
echo "      Removing existing NM docker bridge profiles..."
for profile in $(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
    | awk -F: '$2 ~ /^docker|^br-/ {print $1}'); do
  nmcli connection delete "$profile" 2>/dev/null && echo "      Deleted profile: $profile" || true
done

systemctl reload NetworkManager 2>/dev/null || true
echo "      NetworkManager reloaded"

# ── Fix 4: Ensure Docker starts after firewalld is fully ready ────────────
# Closes the remaining boot-ordering window where firewalld hasn't finished
# initialising zones before Docker tries to register docker0.
echo "[4/4] Adding systemd startup ordering for Docker..."

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target firewalld.service
Wants=network-online.target
EOF
systemctl daemon-reload
echo "      Written: /etc/systemd/system/docker.service.d/override.conf"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo " All fixes applied. Changes take full effect after reboot."
echo ""
echo " Applied:"
echo "   /etc/docker/daemon.json                           (nftables backend)"
echo "   /etc/sysctl.d/99-docker-ipforward.conf            (IP forwarding)"
echo "   /etc/NetworkManager/conf.d/docker-unmanaged.conf  (NM bridge ignore)"
echo "   /etc/systemd/system/docker.service.d/override.conf (boot ordering)"
echo ""
echo " Run: sudo reboot"
echo "======================================================================"
