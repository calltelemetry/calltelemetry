#! /bin/bash
rm docker-compose.yml
wget https://storage.googleapis.com/ct_ovas/docker-compose.yml
systemctl stop docker-compose-app.service
docker-compose pull
systemctl start docker-compose-app.service