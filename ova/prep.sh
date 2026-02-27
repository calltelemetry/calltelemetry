#!/bin/sh -eux
sudo hostname ct-appliance

# Detect installation user and directory
if [ -n "${SUDO_USER:-}" ]; then
  INSTALL_USER="$SUDO_USER"
  INSTALL_DIR=$(eval echo "~$SUDO_USER")
else
  INSTALL_USER=$(whoami)
  INSTALL_DIR="$HOME"
fi

echo "Installation user: $INSTALL_USER"
echo "Installation directory: $INSTALL_DIR"

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

# Ensure install user has docker access
sudo usermod -aG docker "$INSTALL_USER"
sudo chown -R "$INSTALL_USER" "$INSTALL_DIR"

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
cd "$INSTALL_DIR"
chown -R "$INSTALL_USER" "$INSTALL_DIR"

# Prep SFTP root
mkdir "$INSTALL_DIR/sftp" -p
chown "$INSTALL_USER" "$INSTALL_DIR/sftp"

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
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=/etc/network-environment
ExecStart=${DOCKER_COMPOSE_CMD} up -d --remove-orphans
ExecStop=${DOCKER_COMPOSE_CMD} down
TimeoutStartSec=120
Restart=on-failure
RestartSec=60

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
echo "0 0 * * * $INSTALL_USER $INSTALL_DIR/backup.sh" | sudo tee -a /etc/crontab > /dev/null

# GCS base URL (no GitHub dependency)
GCS_BASE_URL="https://storage.googleapis.com/ct_releases"

# Downloads utility scripts (reset.sh, backup.sh) unless they already exist locally
# (e.g., when running from Packer where files are pre-copied)
if [ ! -f "$INSTALL_DIR/reset.sh" ]; then
  echo "Downloading reset.sh from GCS..."
  wget "${GCS_BASE_URL}/reset.sh" -O "$INSTALL_DIR/reset.sh"
else
  echo "reset.sh already exists locally, skipping download"
fi
sudo chmod +x "$INSTALL_DIR/reset.sh"

# Prep Backup Directory and Script
sudo mkdir "$INSTALL_DIR/backups" -p
sudo chown -R "$INSTALL_USER" "$INSTALL_DIR/backups"
if [ ! -f "$INSTALL_DIR/backup.sh" ]; then
  echo "Downloading backup.sh from GCS..."
  wget "${GCS_BASE_URL}/backup.sh" -O "$INSTALL_DIR/backup.sh"
else
  echo "backup.sh already exists locally, skipping download"
fi
sudo chmod +x "$INSTALL_DIR/backup.sh"
sudo chown "$INSTALL_USER" "$INSTALL_DIR/backup.sh"

sudo usermod -aG docker "$INSTALL_USER"
sudo systemctl restart docker

# Set login banners (issue for local console, issue.net for SSH, motd for post-login)
BANNER_CONTENT='Call Telemetry Appliance

   ______      ____   ______     __                    __
  / ____/___ _/ / /  /_  __/__  / /__  ____ ___  ___  / /________  __
 / /   / __ `/ / /    / / / _ \/ / _ \/ __ `__ \/ _ \/ __/ ___/ / / /
/ /___/ /_/ / / /    / / /  __/ /  __/ / / / / /  __/ /_/ /  / /_/ /
\____/\__,_/_/_/    /_/  \___/_/\___/_/ /_/ /_/\___/\__/_/   \__, /
                                                            /____/

https://calltelemetry.com
'

# Console login banner with dynamic info
sudo tee /etc/issue > /dev/null <<EOF
${BANNER_CONTENT}
Hostname: \n
System IP Address: \4
Mgmt: https://\4
EOF

# SSH banner (no escape sequences)
sudo tee /etc/issue.net > /dev/null <<EOF
${BANNER_CONTENT}
EOF

# Post-login MOTD
sudo tee /etc/motd > /dev/null <<EOF
${BANNER_CONTENT}
Run 'cli.sh' for appliance management.
EOF

# Suppress kernel bridge/STP "entering blocking state" messages on console
# These flood the console when Docker creates bridge networks
sudo tee /etc/sysctl.d/99-quiet-console.conf > /dev/null <<EOF
# Suppress noisy kernel messages on console (bridge STP, etc.)
kernel.printk = 3 4 1 3
EOF
sudo sysctl -p /etc/sysctl.d/99-quiet-console.conf 2>/dev/null || true

# Disable kernel bridge module logging to console
echo "options bridge bridge_nf_call_iptables=0" | sudo tee /etc/modprobe.d/bridge.conf > /dev/null 2>/dev/null || true

echo "Appliance prep complete."
echo "IMPORTANT - After this next step you must access the appliance on port 2222 - NOT PORT 22."

# Support non-interactive mode for automated builds (Packer, CI, etc.)
# Set CT_NONINTERACTIVE=1 to skip the interactive prompt and apply SSH port change automatically
if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then
  echo "Non-interactive mode detected. Applying SSH port change automatically..."
  response="yes"
else
  # Prompt the user for confirmation to apply the SSH port change
  read -p "The SSH management port must changed to 2222. Applying this change will disconnect your SSH session. Do you want to apply this change and restart the SSH service? (yes/no): " response < /dev/tty
fi

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
