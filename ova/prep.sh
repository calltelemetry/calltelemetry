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
  if command -v docker-compose >/dev/null 2>&1;
 then
    # Test if it works
    if docker-compose version >/dev/null 2>&1;
 then
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

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
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
echo "0 0 * * * $INSTALL_USER $INSTALL_DIR/backup.sh" | sudo tee -a /etc/crontab > /dev/null

# GCS base URL (no GitHub dependency)
GCS_BASE_URL="https://storage.googleapis.com/ct_releases"

ensure_script() {
  # Usage: ensure_script <name> <url>
  local name="$1"
  local url="$2"
  local local_path="${INSTALL_DIR}/${name}"

  # If already present (e.g., bundled into an image build), prefer it.
  if [ -f "${local_path}" ]; then
    echo "Using bundled ${name} at ${local_path}"
    sudo chmod +x "${local_path}" || true
    return 0
  fi

  # Otherwise attempt download; do not hard-fail image builds if the remote is unavailable.
  echo "Downloading ${name} from ${url}..."
  if wget "${url}" -O "${local_path}"; then
    sudo chmod +x "${local_path}" || true
    return 0
  fi

  echo "WARNING: Failed to download ${name} from ${url}. Continuing without it."
  return 0
}

# Downloads utility scripts (or uses bundled copies if present)
ensure_script "reset.sh" "${GCS_BASE_URL}/reset.sh"

# Prep Backup Directory and Script
sudo mkdir "$INSTALL_DIR/backups" -p
sudo chown -R "$INSTALL_USER" "$INSTALL_DIR/backups"
ensure_script "backup.sh" "${GCS_BASE_URL}/backup.sh"
sudo chown "$INSTALL_USER" "$INSTALL_DIR/backup.sh" 2>/dev/null || true

sudo usermod -aG docker "$INSTALL_USER"
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

# SSH port change controls (defaults preserve interactive behavior).
# - CT_NONINTERACTIVE=1 skips the /dev/tty prompt.
# - CT_SSH_PORT sets the desired SSH port (default: 2222).
# - CT_APPLY_SSH_PORT_CHANGE=1 applies the config change (default: prompt-driven).
# - CT_RESTART_SSHD=1 restarts sshd to apply immediately (default: 1 for interactive flow).
CT_SSH_PORT="${CT_SSH_PORT:-2222}"
CT_RESTART_SSHD="${CT_RESTART_SSHD:-1}"

apply_ssh_port_change=""
if [ -n "${CT_APPLY_SSH_PORT_CHANGE:-}" ]; then
  apply_ssh_port_change="$CT_APPLY_SSH_PORT_CHANGE"
elif [ -n "${CT_NONINTERACTIVE:-}" ]; then
  apply_ssh_port_change="1"
else
  # Prompt the user for confirmation to apply the SSH port change
  read -p "The SSH management port must be changed to ${CT_SSH_PORT}. Applying this change may disconnect your SSH session. Apply now? (yes/no): " response < /dev/tty
  if [ "$response" = "yes" ]; then
    apply_ssh_port_change="1"
  else
    apply_ssh_port_change="0"
  fi
fi

if [ "$apply_ssh_port_change" = "1" ]; then
  # Ensure sshd_config contains ONLY the desired Port line.
  # Multiple Port lines cause sshd to listen on multiple ports, which can keep 22 occupied.
  sudo sed -i -E '/^[[:space:]]*#?Port[[:space:]]+[0-9]+/d' /etc/ssh/sshd_config
  echo "Port ${CT_SSH_PORT}" | sudo tee -a /etc/ssh/sshd_config > /dev/null

  echo "Configuring firewall for port ${CT_SSH_PORT}"

  # Ensure firewalld is available/running before attempting firewall-cmd.
  if ! command -v firewall-cmd >/dev/null 2>&1;
 then
    sudo dnf install -y firewalld || sudo yum install -y firewalld || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1;
 then
    sudo systemctl enable --now firewalld 2>/dev/null || true
  fi

  # Detect AlmaLinux, CentOS, or RHEL and handle accordingly
  if grep -q "AlmaLinux" /etc/os-release;
 then
    echo "Detected Alma Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp "${CT_SSH_PORT}" 2>/dev/null || sudo semanage port -m -t ssh_port_t -p tcp "${CT_SSH_PORT}"
    sudo firewall-cmd --zone=public --add-port="${CT_SSH_PORT}/tcp" --permanent
    # Keep port 22 open for the appliance to bind (SFTP, etc.) while moving OS sshd off 22.
    sudo firewall-cmd --zone=public --add-port="22/tcp" --permanent 2>/dev/null || true
    sudo firewall-cmd --reload

  elif grep -q "CentOS" /etc/os-release;
 then
    echo "Detected CentOS Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp "${CT_SSH_PORT}" 2>/dev/null || sudo semanage port -m -t ssh_port_t -p tcp "${CT_SSH_PORT}"
    sudo firewall-cmd --zone=public --add-port="${CT_SSH_PORT}/tcp" --permanent
    sudo firewall-cmd --zone=public --add-port="22/tcp" --permanent 2>/dev/null || true
    sudo firewall-cmd --reload

  elif grep -q "Red Hat Enterprise Linux" /etc/os-release;
 then
    echo "Detected Red Hat Enterprise Linux. Installing semanage tools and configuring firewall..."
    sudo yum install policycoreutils-python-utils -y
    sudo semanage port -a -t ssh_port_t -p tcp "${CT_SSH_PORT}" 2>/dev/null || sudo semanage port -m -t ssh_port_t -p tcp "${CT_SSH_PORT}"
    sudo firewall-cmd --zone=public --add-port="${CT_SSH_PORT}/tcp" --permanent
    sudo firewall-cmd --zone=public --add-port="22/tcp" --permanent 2>/dev/null || true
    sudo firewall-cmd --reload

  else
      echo "Unsupported OS. Please make sure your firewall allows access to port ${CT_SSH_PORT}"
  fi

  # Restart SSH service (optional).
  # For image-building workflows (e.g., Packer), you can set CT_RESTART_SSHD=0 to avoid disconnecting.
  if [ "$CT_RESTART_SSHD" = "1" ]; then
    # Validate config before applying.
    if ! sudo sshd -t 2>/dev/null;
 then
      echo "ERROR: sshd_config validation failed; refusing to reload/restart sshd."
      exit 1
    fi

    # Prefer reload to avoid dropping existing SSH sessions (restart may kill the current connection).
    if sudo systemctl reload sshd 2>/dev/null;
 then
      echo "sshd reloaded."
    else
      sudo systemctl restart sshd
      echo "sshd restarted."
    fi

    # Verify the listener moved and port 22 is freed.
    if command -v ss >/dev/null 2>&1;
 then
      sudo ss -ltnp 2>/dev/null | grep -E ':(22|'"${CT_SSH_PORT}"'[[:space:]]' || true
      if sudo ss -ltnp 2>/dev/null | grep -E ':22\b' | grep -q sshd;
 then
        echo "ERROR: sshd is still listening on port 22 (expected to be freed)."
        exit 1
      fi
      if ! sudo ss -ltnp 2>/dev/null | grep -E ":${CT_SSH_PORT}\b" | grep -q sshd;
 then
        echo "ERROR: sshd is not listening on port ${CT_SSH_PORT}."
        exit 1
      fi
    fi
  else
    echo "Skipping sshd restart (CT_RESTART_SSHD=0). SSH port change will apply on next boot/restart."
  fi
else
  echo "The SSH port change was not applied. Please rerun the script and choose 'yes' to complete the setup."
fi