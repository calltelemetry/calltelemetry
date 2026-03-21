#!/usr/bin/env bash
# k3s-appliance-prep.sh — Build-time provisioner for K3s appliance OVA
# Runs during Packer build. Installs K3s, Helm, Helmfile, pre-deploys the
# full CallTelemetry stack via helmfile to pull all images, then stops K3s.
# First-boot wizard (k3s-firstboot.sh) re-applies with real network values.
set -euo pipefail

INSTALL_USER="${SUDO_USER:-$(whoami)}"
INSTALL_DIR="$(eval echo ~${INSTALL_USER})"
K8S_DIR="/opt/calltelemetry/k8s"

echo "=== K3s Appliance Prep ==="
echo "User: ${INSTALL_USER}"
echo "Home: ${INSTALL_DIR}"

# ─── OS Prep ───────────────────────────────────────────────────────────────

sudo hostname ct-appliance

# Basic packages
sudo dnf install -y wget net-tools git policycoreutils-python-utils

# ─── SSH port 2222 (free port 22 for SFTP) ────────────────────────────────

sudo sed -i "s/#Port 22/Port 2222/" /etc/ssh/sshd_config
sudo semanage port -a -t ssh_port_t -p tcp 2222 || true
sudo firewall-cmd --zone=public --add-port=2222/tcp --permanent

# ─── Firewall rules for K3s + MetalLB + app services ──────────────────────

# K3s API server
sudo firewall-cmd --permanent --add-port=6443/tcp
# etcd
sudo firewall-cmd --permanent --add-port=2379-2380/tcp
# Kubelet
sudo firewall-cmd --permanent --add-port=10250/tcp
# kube-scheduler / kube-controller-manager
sudo firewall-cmd --permanent --add-port=10251-10252/tcp
# Flannel VXLAN
sudo firewall-cmd --permanent --add-port=8285/udp
sudo firewall-cmd --permanent --add-port=8472/udp
# MetalLB memberlist
sudo firewall-cmd --permanent --add-port=7946/tcp
sudo firewall-cmd --permanent --add-port=7946/udp
# NodePort range
sudo firewall-cmd --permanent --add-port=30000-32767/tcp
# App services: HTTP, HTTPS, SFTP, Syslog
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --permanent --add-port=514/tcp
sudo firewall-cmd --permanent --add-port=514/udp
# Masquerade for K3s networking
sudo firewall-cmd --add-masquerade --permanent
sudo firewall-cmd --reload

# ─── Network environment discovery ────────────────────────────────────────

sudo mkdir -p /opt/bin
sudo wget -N -P /opt/bin https://github.com/kelseyhightower/setup-network-environment/releases/download/v1.0.0/setup-network-environment
sudo chmod +x /opt/bin/setup-network-environment

sudo tee /etc/systemd/system/setup-network-environment.service > /dev/null <<'EOF'
[Unit]
Description=Setup Network Environment
Documentation=https://github.com/kelseyhightower/setup-network-environment
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/opt/bin/setup-network-environment
RemainAfterExit=yes
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable setup-network-environment

# ─── Login banners ─────────────────────────────────────────────────────────

BANNER_CONTENT='Call Telemetry Appliance (K3s)

   ______      ____   ______     __                    __
  / ____/___ _/ / /  /_  __/__  / /__  ____ ___  ___  / /________  __
 / /   / __ `/ / /    / / / _ \/ / _ \/ __ `__ \/ _ \/ __/ ___/ / / /
/ /___/ /_/ / / /    / / /  __/ /  __/ / / / / /  __/ /_/ /  / /_/ /
\____/\__,_/_/_/    /_/  \___/_/\___/_/ /_/ /_/\___/\__/_/   \__, /
                                                            /____/

https://calltelemetry.com — Kubernetes Edition
'

sudo tee /etc/issue > /dev/null <<EOF
${BANNER_CONTENT}
Hostname: \n
System IP Address: \4
Mgmt: https://\4
EOF

sudo tee /etc/issue.net > /dev/null <<EOF
${BANNER_CONTENT}
EOF

sudo tee /etc/motd > /dev/null <<EOF
${BANNER_CONTENT}
Run 'ct shell' for appliance management.
Run 'kubectl get pods -n ct' to check services.
EOF

# ─── Node.js + ct-cli ──────────────────────────────────────────────────────

REQUIRED_NODE_MAJOR=22
CURRENT_NODE_MAJOR=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo "0")
CURRENT_NODE_MAJOR="${CURRENT_NODE_MAJOR:-0}"

if [ "${CURRENT_NODE_MAJOR}" -lt "${REQUIRED_NODE_MAJOR}" ] 2>/dev/null; then
  echo "Installing Node.js ${REQUIRED_NODE_MAJOR} LTS..."
  sudo dnf remove -y nodejs npm 2>/dev/null || true
  curl -fsSL https://rpm.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x | sudo bash -
  sudo dnf install -y nodejs
fi

echo "Installing @calltelemetry/cli..."
sudo /usr/bin/npm install -g @calltelemetry/cli
echo "ct-cli $(ct --version 2>/dev/null || echo 'installed') ready."

# ─── k9s ────────────────────────────────────────────────────────────────────

if ! command -v k9s &>/dev/null; then
  echo "Installing k9s..."
  K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep "tag_name" | cut -d '"' -f 4)
  wget -q "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" -O /tmp/k9s.tar.gz
  sudo tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
  rm -f /tmp/k9s.tar.gz
fi

# ─── Install K3s ────────────────────────────────────────────────────────────

echo "Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable \
  K3S_KUBECONFIG_MODE=0644 \
  sh -s server \
  --cluster-init \
  --disable traefik \
  --disable servicelb

# Wait for K3s to be ready
echo "Waiting for K3s node to be Ready..."
for i in $(seq 1 60); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    echo "K3s node is Ready."
    break
  fi
  sleep 5
done

# Setup kubeconfig for the install user
sudo mkdir -p "${INSTALL_DIR}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${INSTALL_DIR}/.kube/config"
sudo chown -R "${INSTALL_USER}:${INSTALL_USER}" "${INSTALL_DIR}/.kube"
export KUBECONFIG="${INSTALL_DIR}/.kube/config"

# Also set for root
sudo mkdir -p /root/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /root/.kube/config

# ─── Install Helm ───────────────────────────────────────────────────────────

echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── Install Helmfile ───────────────────────────────────────────────────────

echo "Installing Helmfile..."
HELMFILE_VERSION="${HELMFILE_VERSION:-0.169.2}"
wget -q "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" -O /tmp/helmfile.tar.gz
sudo tar -xzf /tmp/helmfile.tar.gz -C /usr/local/bin helmfile
sudo chmod +x /usr/local/bin/helmfile
rm -f /tmp/helmfile.tar.gz

# Install helm-diff plugin (required by helmfile)
helm plugin install https://github.com/databus23/helm-diff || true

# ─── Copy Helm charts into appliance ────────────────────────────────────────

echo "Setting up Helm charts at ${K8S_DIR}..."
sudo mkdir -p "${K8S_DIR}"
# The k8s/ directory was already copied by the Packer file provisioner
if [ -d "/home/${INSTALL_USER}/k8s" ]; then
  sudo cp -r "/home/${INSTALL_USER}/k8s/"* "${K8S_DIR}/"
  sudo chown -R root:root "${K8S_DIR}"
fi

# ─── Pre-deploy via Helmfile (pulls all images + initializes DB) ────────────

echo "Pre-deploying CallTelemetry stack via helmfile (placeholder IPs)..."
cd "${K8S_DIR}"

# Add Helm repos first
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts || true
helm repo add metallb https://metallb.github.io/metallb || true
helm repo add nats https://nats-io.github.io/k8s/helm/charts || true
helm repo add cnpg https://cloudnative-pg.github.io/charts || true
helm repo add calltelemetry https://calltelemetry.github.io/k8s/helm/charts || true
helm repo add jetstack https://charts.jetstack.io || true
helm repo update

# Create the namespace
kubectl create namespace ct --dry-run=client -o yaml | kubectl apply -f -

# Run helmfile sync to deploy everything and pull all images
helmfile --environment ct-appliance sync || {
  echo "WARNING: helmfile sync had errors (may be normal for placeholder IPs)"
  echo "Images should still be pulled. Continuing..."
}

echo "Waiting for pods to settle..."
sleep 30

# Show what's running
kubectl get pods -n ct -o wide 2>/dev/null || true
kubectl get pods -n metallb-system -o wide 2>/dev/null || true
kubectl get pods -n cnpg-system -o wide 2>/dev/null || true
kubectl get pods -n cert-manager -o wide 2>/dev/null || true

# List pre-pulled images
echo "Pre-pulled container images:"
sudo k3s crictl images 2>/dev/null | head -30 || true

# ─── Stop K3s (images persist in containerd) ─────────────────────────────────

echo "Stopping K3s (images persist for first-boot)..."
sudo systemctl stop k3s

# ─── Lock deployment mode to K8s ─────────────────────────────────────────────

echo "k8s" | sudo tee /etc/ct-deploy-mode > /dev/null

# ─── First-boot entry point ──────────────────────────────────────────────────

# Copy firstboot script
if [ -f "/home/${INSTALL_USER}/k3s-firstboot.sh" ]; then
  sudo cp "/home/${INSTALL_USER}/k3s-firstboot.sh" /opt/calltelemetry/k3s-firstboot.sh
  sudo chmod +x /opt/calltelemetry/k3s-firstboot.sh
fi

# Profile hook: on first interactive login, run the K3s first-boot wizard
sudo tee /etc/profile.d/ct-firstboot.sh > /dev/null <<'PROFILE_EOF'
#!/bin/bash
# ct-firstboot.sh — First-boot entry point for K3s Call Telemetry Appliance
# Detects K3s mode and runs setup wizard if not yet configured.
[ -t 0 ] || return 0

# Check if K3s appliance needs first-boot configuration
if [ -f /etc/ct-deploy-mode ] && [ "$(cat /etc/ct-deploy-mode)" = "k8s" ]; then
  if [ ! -f /etc/ct-k3s-configured ]; then
    echo ""
    echo "K3s appliance detected — running first-boot setup..."
    echo ""
    sudo /opt/calltelemetry/k3s-firstboot.sh
    return 0
  fi
fi

# Normal operation: launch ct shell if available
command -v ct >/dev/null 2>&1 || return 0
exec ct shell
PROFILE_EOF
sudo chmod +x /etc/profile.d/ct-firstboot.sh

# ─── Backup cron job ─────────────────────────────────────────────────────────

sudo mkdir -p "${INSTALL_DIR}/backups"
sudo chown -R "${INSTALL_USER}" "${INSTALL_DIR}/backups"
if [ -f "${INSTALL_DIR}/backup.sh" ]; then
  sudo chmod +x "${INSTALL_DIR}/backup.sh"
  echo "0 0 * * * ${INSTALL_USER} ${INSTALL_DIR}/backup.sh" | sudo tee -a /etc/crontab > /dev/null
fi

# ─── SSH reload (switch to port 2222, preserves Packer session) ──────────────

echo "Reloading SSH on port 2222..."
sudo systemctl reload sshd || sudo systemctl restart sshd

# ─── Suppress noisy console messages ──────────────────────────────────────────

sudo tee /etc/sysctl.d/99-quiet-console.conf > /dev/null <<'EOF'
kernel.printk = 3 4 1 3
EOF
sudo sysctl -p /etc/sysctl.d/99-quiet-console.conf 2>/dev/null || true

# ─── Fix NetworkManager permissions ───────────────────────────────────────────

for f in /etc/NetworkManager/system-connections/*.nmconnection; do
  sudo sed -i 's/permissions=user:root:;//' "$f" 2>/dev/null || true
done
sudo nmcli connection reload 2>/dev/null || true

echo ""
echo "=== K3s Appliance Prep Complete ==="
echo "K3s + Helm + Helmfile installed"
echo "All container images pre-pulled"
echo "Deploy mode locked to: k8s"
echo "SSH management port: 2222"
echo "First-boot wizard will run on next login"
