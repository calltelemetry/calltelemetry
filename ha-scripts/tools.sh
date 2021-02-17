#!/bin/bash
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
