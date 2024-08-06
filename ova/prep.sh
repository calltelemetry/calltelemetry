#!/bin/sh -eux
sudo hostname ct-appliance

# If CentOS
if [[ -f /etc/centos-release ]]; then
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

# If RHEL / AlmaLinux
if [[ -f /etc/redhat-release ]]; then
  sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi

# Install Docker-Compose
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --nobest

# Enable and Start Docker
sudo systemctl enable --now docker

# Add calltelemetry user
if id "calltelemetry" >/dev/null 2>&1; then
  echo "User calltelemetry exists."
else
  echo "User calltelemetry does not exist."
  sudo useradd -m calltelemetry
  echo "calltelemetry" | passwd calltelemetry --stdin
  sudo usermod -aG docker calltelemetry
  sudo usermod -aG wheel calltelemetry
fi

sudo chown -R calltelemetry /home/calltelemetry

# Setup Docker compose
sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Setup Call Telemetry Home
cd /home/calltelemetry/
chown -R calltelemetry /home/calltelemetry

# Prep SFTP root
mkdir /home/calltelemetry/sftp -p
chown calltelemetry /home/calltelemetry/sftp

# Install the setup-network-environment binary
# This helps discover the host IP address and other network settings
# Author - https://github.com/kelseyhightower/setup-network-environment
sudo mkdir -p /opt/bin
sudo wget -N -P /opt/bin https://github.com/kelseyhightower/setup-network-environment/releases/download/v1.0.0/setup-network-environment
sudo chmod +x /opt/bin/setup-network-environment

sudo tee /etc/systemd/system/setup-network-environment.service > /dev/null <<EOF
#/etc/systemd/system/setup-network-environment.service
[Unit]
Description=Setup Network Environment
Documentation=https://github.com/kelseyhightower/setup-network-environment
Requires=network-online.target
After=network-online.target

[Service]
ExecStart=/opt/bin/setup-network-environment
RemainAfterExit=yes
Type=oneshot
EOF

# Install Docker Compose Service
sudo tee /etc/systemd/system/docker-compose-app.service > /dev/null <<EOF
[Unit]
Description=Docker Compose CallTelemetry
Requires=setup-network-environment.service
After=setup-network-environment.service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/calltelemetry
EnvironmentFile=/etc/network-environment
# ExecStartPre=/usr/bin/docker-compose pull --quiet --ignore-pull-failures
# ExecStartPre=/usr/bin/docker-compose build --pull
ExecStart=/usr/bin/docker-compose up -d --remove-orphans
ExecStop=/usr/bin/docker-compose down
# ExecReload=/usr/bin/docker-compose pull --quiet --ignore-pull-failures
# ExecReload=/usr/bin/docker-compose build --pull
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

# Enable Docker Log rotation
sudo tee /etc/logrotate.d/docker > /dev/null <<EOF
/var/lib/docker/containers/*/*.log {
 rotate 7
 daily
 compress
 size=50M
 missingok
 delaycompress
 copytruncate
}
EOF

sudo systemctl enable docker.service --now
sudo systemctl enable docker-compose-app

# Setup a Backup Job
sudo tee -a /etc/crontab > /dev/null <<'EOF'
0 0 * * * calltelemetry /home/calltelemetry/backup.sh
EOF

# Downloads a utility reset script
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/reset.sh -O reset.sh
sudo chmod +x /home/calltelemetry/reset.sh

# Prep Backup Directory and Script
sudo mkdir /home/calltelemetry/backups -p
sudo chown -R calltelemetry /home/calltelemetry/backups
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/backup.sh -O /home/calltelemetry/backup.sh
sudo chmod +x /home/calltelemetry/backup.sh
sudo chown calltelemetry /home/calltelemetry/backup.sh

sudo usermod -aG docker calltelemetry

sudo tee /etc/issue > /dev/null <<'EOF'
Call Telemetry Appliance

   ______      ____   ______     __                    __
  / ____/___ _/ / /  /_  __/__  / /__  ____ ___  ___  / /________  __
 / /   / __ `/ / /    / / / _ \/ / _ \/ __ `__ \/ _ \/ __/ ___/ / / /
/ /___/ /_/ / / /    / / /  __/ /  __/ / / / / /  __/ /_/ /  / /_/ /
\____/\__,_/_/_/    /_/  \___/_/\___/_/ /_/ /_/\___/\__/_/   \__, /
                                                            /____/

https://calltelemetry.com

Hostname: \n
System IP Address: \4
Mgmt: https://\4
EOF

echo "Appliance prep complete."
echo "IMPORTANT - After this next step you must access the appliance on port 2222 - NOT PORT 22."

# Prompt the user for confirmation to apply the SSH port change
read -p "The SSH management port must changed to 2222. Applying this change will disconnect your SSH session. Do you want to apply this change and restart the SSH service? (yes/no): " response < /dev/tty

if [ "$response" = "yes" ]; then
  # Change SSH port to 2222
  sudo sed -i "s/#Port 22/Port 2222/" /etc/ssh/sshd_config

  # If RHEL or AlmaLinux, add 2222 to SELinux
  if [[ -f /etc/redhat-release ]]; then
    sudo semanage port -a -t ssh_port_t -p tcp 2222
    sudo firewall-cmd --zone=public --add-port=2222/tcp --permanent
    sudo firewall-cmd --reload
  fi

  # Restart SSH service
  sudo systemctl restart sshd
else
  echo "The SSH port change was not applied. Please rerun the script and choose 'yes' to complete the setup."
fi
