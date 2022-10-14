#! /bin/bash
# Backup Docker config
mv docker-compose.yml old-docker-compose.yml
# Download new docker compose file
wget https://storage.googleapis.com/ct_ovas/docker-compose.yml -O docker-compose.yml
# Pull new image
docker-compose pull
# Restart docker
systemctl restart docker-compose-app.service
# Refresh OVA scripts
rm backup.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/backup.sh -O backup.sh
chmod +x backup.sh
# Fix for appliance permissions on pre-0.6.8
sudo chown -R calltelemetry /home/calltelemetry/backups
chmod +x /home/calltelemetry/backup.sh
chown calltelemetry /home/calltelemetry/backup.sh
rm update.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/update.sh -O update.sh
chmod +x update.sh
rm reset.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/reset.sh -O reset.sh
chmod +x reset.sh

