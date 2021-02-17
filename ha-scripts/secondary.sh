#!/bin/bash
export primary_ip="192.168.123.135"
export K3S_URL="https://$primary_ip:6443"
export INSTALL_K3S_CHANNEL=stable
export K3S_KUBECONFIG_MODE="0644"
# Note: This token is a preshared-key shared between the cluster. It should be changed for production use.
export K3S_TOKEN="calltelemetry"

# Install Kubectl and Helm via SNAPS
sudo yum install -y wget epel-release snapd
sudo systemctl enable --now snapd.socket
sudo ln -s /var/lib/snapd/snap /snap
sudo snap wait system seed.loaded
sudo systemctl restart snapd.seeded.service
sudo snap install kubectl --classic
sudo snap install helm --classic

# Install K9s Kubernetes Management tool
echo "Installing k9s toolkit - https://github.com/derailed/k9s/"
wget https://github.com/derailed/k9s/releases/download/v0.24.2/k9s_Linux_x86_64.tar.gz
tar -xzf k9s_Linux_x86_64.tar.gz
sudo mv k9s /usr/local/bin
mkdir ~/.k9s
rm -rf k9s*

# Install Master
curl -sfL https://get.k3s.io | sh -s server --no-deploy traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config