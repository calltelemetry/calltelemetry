#!/bin/bash
# Runs on CentOS Strema, Almalinux or RHEL
# This script will install the necessary tools to run the Call Telemetry application on Kubernetes

# Need 2379 and 2380 for ETCD HA
sudo firewall-cmd --permanent --add-port=2379/tcp
sudo firewall-cmd --permanent --add-port=2380/tcp
# Need 7946 for k3s MetalLB
sudo firewall-cmd --permanent --add-port=7946/tcp
sudo firewall-cmd --permanent --add-port=7946/udp
# Need 443 for HTTPS
sudo firewall-cmd --permanent --add-port=443/tcp
# Need 80 for HTTP
sudo firewall-cmd --permanent --add-port=80/tcp
# Need 22 for SSH, and 2222 for Admin SSH
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --permanent --add-port=2222/tcp
# Need 6443 for Kube API
sudo firewall-cmd --permanent --add-port=6443/tcp
# Need 10250 and 10251 and 10259 and 10257 for Kubelet API, Kubelet Metrics, Kubelet and Kube Proxy
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=10251/tcp
sudo firewall-cmd --permanent --add-port=10259/tcp
sudo firewall-cmd --permanent --add-port=10257/tcp
# Need 30000-32767 for K8s NodePort Traffic
sudo firewall-cmd --permanent --add-port=30000-32767/tcp
sudo firewall-cmd --reload

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
wget https://github.com/derailed/k9s/releases/download/v0.40.10/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_*
sudo mv k9s /usr/local/bin
mkdir ~/.k9s -p
rm -rf k9s*

# Install GIT
sudo dnf install -y git

# Clone repo
git clone https://github.com/calltelemetry/calltelemetry.git

echo "cd calltelemetry/ha-scripts, and run master.sh or secondary.sh"
