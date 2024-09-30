#!/bin/bash
# Runs on CentOS Strema, Almalinux or RHEL
# This script will install the necessary tools to run the Call Telemetry application on Kubernetes

# Disable Firewall and selinux
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo setenforce permissive
sudo systemctl disable rpcbind

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
wget https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_*
sudo mv k9s /usr/local/bin
mkdir ~/.k9s -p
rm -rf k9s*

# Install GIT
sudo dnf install -y git

# Clone repo
git clone https://github.com/calltelemetry/calltelemetry.git

echo "cd calltelemetry/ha-scripts, and run master.sh or secondary.sh"
