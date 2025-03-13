#!/bin/bash
# Edit this to be the primary node ip
export primary_ip="192.168.123.156"
#This token is a preshared-key shared between the cluster. It's generated dynamically on the primary node.
# get it by sudo cat /var/lib/rancher/k3s/server/node-token
# Default from the master script was calltelemetry

export K3S_TOKEN=calltelemetry
# Node
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=8285/udp # Flannel
firewall-cmd --permanent --add-port=8472/udp # Flannel
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --add-masquerade --permanent
firewall-cmd --reload
systemctl restart firewalld

# Install Secondary
sudo curl -sfL https://get.k3s.io | NSTALL_K3S_CHANNEL=stable K3S_URL="https://$primary_ip:6443" K3S_KUBECONFIG_MODE=0644 sh -s server --disable traefik --disable servicelb
# Upgrade Example
# sudo curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.30.5+k3s1  K3S_URL="https://$primary_ip:6443" K3S_KUBECONFIG_MODE=0644 sh -s server --disable traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

echo "Scaling DNS in Kuberentes to match node count"
/snap/bin/kubectl scale deployment.v1.apps/coredns --replicas=3 -n kube-system
