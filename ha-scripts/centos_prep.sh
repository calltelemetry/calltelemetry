#!/bin/bash
# Disable Firewall and selinux
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo setenforce permissive

# Install Kubectl and Helm via SNAPS
sudo yum install -y wget epel-release 
sudo yum install -y snapd
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

# Install GIT
sudo dnf install -y git

# Clone repo
git clone https://github.com/calltelemetry/calltelemetry.git

echo "cd calltelemetry/ha-scripts, and run master.sh or secondary.sh"
