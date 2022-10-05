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
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/backup.sh -o backup.sh
chmod +x backup.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/update.sh -o update.sh
chmod +x update.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/reset.sh -o reset.sh
chmod +x reset.sh

