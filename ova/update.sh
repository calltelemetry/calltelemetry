#!/bin/bash

# Detect installation user and directory
if [ -n "${SUDO_USER:-}" ]; then
  INSTALL_USER="$SUDO_USER"
  INSTALL_DIR=$(eval echo "~$SUDO_USER")
else
  INSTALL_USER=$(whoami)
  INSTALL_DIR="$HOME"
fi

cd "$INSTALL_DIR"

# Backup Docker config, if it exists.
mv docker-compose.yml old-docker-compose.yml
# Download new docker compose file
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml -O docker-compose.yml
# Pull new image
docker-compose pull

# Migrate Docker to native nftables backend (Docker 29+).
# Eliminates deprecated nft_compat/ip_set module loading and console warnings.
# Safe to apply idempotently — only writes if not already configured.
docker_major=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)

if [ "${docker_major:-0}" -ge 29 ] && ! grep -q '"firewall-backend"' /etc/docker/daemon.json 2>/dev/null; then
  echo "Configuring Docker native nftables backend..."
  mkdir -p /etc/docker
  # Merge with existing daemon.json if present, otherwise create fresh
  if [ -f /etc/docker/daemon.json ]; then
    tmp=$(mktemp)
    python3 -c "
import json, sys
d = json.load(open('/etc/docker/daemon.json'))
d['firewall-backend'] = 'nftables'
json.dump(d, open('$tmp', 'w'), indent=2)
"
    mv "$tmp" /etc/docker/daemon.json
  else
    printf '{\n  "firewall-backend": "nftables"\n}\n' > /etc/docker/daemon.json
  fi
  echo "Docker nftables backend configured."
elif [ "${docker_major:-0}" -lt 29 ]; then
  echo "Docker ${docker_major:-unknown} < 29 — skipping nftables backend (requires Docker 29+)"
fi

# Restart docker
systemctl restart docker-compose-app.service
# Fresh Install & Fix for appliance permissions
mkdir -p backups
sudo chown -R "$INSTALL_USER" backups
# Refresh OVA scripts
rm backup.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/backup.sh -O backup.sh
chmod +x backup.sh
chown "$INSTALL_USER" backup.sh
rm update.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/update.sh -O update.sh
chmod +x update.sh
rm reset.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/reset.sh -O reset.sh
chmod +x reset.sh
rm compact.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/compact.sh -O compact.sh
chmod +x compact.sh
rm -rf "${INSTALL_DIR}/.ssh/authorized_keys"
