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
