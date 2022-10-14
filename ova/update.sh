#! /bin/bash
# Backup Docker config
cp docker-compose.yml old-docker-compose.yml
# Download new docker compose file
wget https://storage.googleapis.com/ct_ovas/docker-compose.yml -o docker-compose.yml
# Pull new image
docker-compose pull
# Restart docker
systemctl restart docker-compose-app.service
# Refresh OVA scripts
rm backup.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/0.6.8/ova/backup.sh -O backup.sh
chmod +x backup.sh
rm update.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/0.6.8/ova/update.sh -O update.sh
chmod +x update.sh
rm reset.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/0.6.8/ova/reset.sh -O reset.sh
chmod +x reset.sh

