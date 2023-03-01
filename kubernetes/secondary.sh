#!/bin/bash
# Edit this to be the primary node.
export primary_ip="192.168.123.156"
#This token is a preshared-key shared between the cluster. It's generated dynamically on the primary node.
# get it by sudo cat /var/lib/rancher/k3s/server/node-token
export K3S_TOKEN="your-super-secret-dynamic-hash-from-node1"

# Install Secondary
sudo curl -sfL https://get.k3s.io | K3S_URL="https://$primary_ip:6443" K3S_KUBECONFIG_MODE=0644 sh -s server --disable traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
