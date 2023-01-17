sudo systemctl stop docker-compose-app
sudo rm -rf sftp/*
sudo rm -rf postgres-data
sudo rm -rf backups/*
sudo systemctl start docker-compose-app
