#!/bin/bash
# Edit this to be the primary node / any master node.
export primary_ip="192.168.123.156"
#his token is a preshared-key shared between the cluster. It should be changed for production use.
export K3S_TOKEN="calltelemetry"

# Nothing below this needs to be edited
export K3S_URL="https://$primary_ip:6443"
export INSTALL_K3S_CHANNEL=stable
export K3S_KUBECONFIG_MODE="0644"

# Install Secondary
curl -sfL https://get.k3s.io | sh -s server  --no-deploy traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
