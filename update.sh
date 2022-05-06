#! /bin/bash
rm docker-compose.yml
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml
sudo docker-compose downw
sudo docker-compose pull
sudo docker-compose up -d