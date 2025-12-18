#!/bin/sh -eux
sudo hostname ct-appliance

# Install wget and basic net tools if not already installed.
sudo dnf install wget net-tools -y


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

# Minimum Docker API version required (1.44 = Docker 25.0+)
MIN_API_VERSION="1.44"

# Check if Docker API version is sufficient
check_docker_api_version() {
  local api_version=$(docker version --format '{{.Client.APIVersion}}' 2>/dev/null || echo "0")
  if [ "$(printf '%s\n' "$MIN_API_VERSION" "$api_version" | sort -V | head -n1)" = "$MIN_API_VERSION" ]; then
    return 0  # Version is sufficient
  else
    return 1  # Version is too old
  fi
}

# Install/upgrade standalone docker-compose to latest version
install_latest_docker_compose() {
  echo "Installing latest docker-compose standalone..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  echo "docker-compose standalone installed."
}

# Detect docker compose command (prefer modern plugin over standalone)
detect_docker_compose_cmd() {
  # Check if modern docker compose plugin works with current API
  if docker compose version >/dev/null 2>&1 && check_docker_api_version; then
    echo "/usr/bin/docker compose"
    return 0
  fi

  # Check standalone docker-compose
  if command -v docker-compose >/dev/null 2>&1; then
    # Test if it works
    if docker-compose version >/dev/null 2>&1; then
      echo "/usr/bin/docker-compose"
      return 0
    fi
  fi

  # Neither works - install latest standalone
  install_latest_docker_compose
  echo "/usr/bin/docker-compose"
}

DOCKER_COMPOSE_CMD=$(detect_docker_compose_cmd)
echo "Using docker compose command: $DOCKER_COMPOSE_CMD"

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
ExecStart=${DOCKER_COMPOSE_CMD} up -d --remove-orphans
ExecStop=${DOCKER_COMPOSE_CMD} down
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
sudo systemctl restart docker

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
  echo "Configuring firewall for port 2222"

  # Detect AlmaLinux, CentOS, or RHEL and handle accordingly
  if grep -q "AlmaLinux" /etc/os-release; then
    echo "Detected Alma Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp 2222
    sudo firewall-cmd --zone=public --add-port=2222/tcp --permanent
    sudo firewall-cmd --reload

  elif grep -q "CentOS" /etc/os-release; then
    echo "Detected CentOS Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp 2222
    sudo firewall-cmd --zone=public --add-port=2222/tcp --permanent
    sudo firewall-cmd --reload

  elif grep -q "Red Hat Enterprise Linux" /etc/os-release; then
    echo "Detected Red Hat Enterprise Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp 2222
    sudo firewall-cmd --zone=public --add-port=2222/tcp --permanent
    sudo firewall-cmd --reload

  else
      echo "Unsupported OS. Please make sure your firewall allows access to port 2222 "
  fi

  # Restart SSH service
  sudo systemctl restart sshd
else
  echo "The SSH port change was not applied. Please rerun the script and choose 'yes' to complete the setup."
fi
