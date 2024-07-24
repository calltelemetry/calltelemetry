#! /bin/bash
# Backup Docker config, if it exists.
mv docker-compose.yml old-docker-compose.yml
# Download new docker compose file
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml -O docker-compose.yml
# Pull new image
docker-compose pull
# Restart docker
systemctl restart docker-compose-app.service
# Fresh Install & Fix for appliance permissions on pre-0.6.8
mkdir -p backups
sudo chown -R calltelemetry backups
# Refresh OVA scripts
rm backup.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/backup.sh -O backup.sh
chmod +x backup.sh
chmod +x backup.sh
chown calltelemetry backup.sh
rm update.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/update.sh -O update.sh
chmod +x update.sh
rm reset.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/reset.sh -O reset.sh
chmod +x reset.sh
rm compact.sh
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/compact.sh -O compact.sh
chmod +x compact.sh
rm -rf /home/calltelemetry/.ssh/authorized_keys
