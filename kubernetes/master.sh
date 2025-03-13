#!/bin/bash

# export NODES=3
# # Primary and Secondary IPs for the CURRI API
export primary_ip="192.168.123.205"
export secondary_ip="192.168.123.206"
# # Virtual IP for the Call Telemetry Management API
export admin_ip="192.168.123.207"
# token is a preshared key among the k3s nodes for HA
export K3S_TOKEN=calltelemetry

# Master
firewall-cmd --permanent --add-port=6443/tcp # Kubernetes API server
firewall-cmd --permanent --add-port=2379-2380/tcp # etcd server client API
firewall-cmd --permanent --add-port=10250/tcp # Kubelet API
firewall-cmd --permanent --add-port=10251/tcp # kube-scheduler
firewall-cmd --permanent --add-port=10252/tcp # kube-controller-manager
firewall-cmd --permanent --add-port=8285/udp # Flannel
firewall-cmd --permanent --add-port=8472/udp # Flannel
firewall-cmd --add-masquerade --permanent
# only if you want NodePorts exposed on control plane IP as well
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --reload
systemctl restart firewalld

# Install K3s on the master
# token is a preshared key among the k3s nodes for HA
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable K3S_KUBECONFIG_MODE=0644 sh -s server --cluster-init --disable traefik --disable servicelb
# Upgrade Example
# curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.30.5+k3s1 K3S_KUBECONFIG_MODE=0644 sh -s server --cluster-init --disable traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

# uninstall:
# /usr/local/bin/k3s-uninstall.sh

kubectl create namespace ct
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
helm install -n ct nats nats/nats

# MetalLB for Load Balancer
kubectl create namespace metallb-system
helm repo add metallb https://metallb.github.io/metallb
# --set crds.validationFailurePolicy=Ignore
helm install -n metallb-system metallb metallb/metallb


echo "Installing CrunchyData PostgreSQL Operator"
# Reference:
# https://access.crunchydata.com/documentation/postgres-operator/latest

# Install the Crunchy Postgres K8s Operator
# Create the namespace
kubectl create namespace postgres-operator
git clone https://github.com/CrunchyData/postgres-operator-examples.git
# Install the PostgreSQL Crunch Operator
kubectl apply --server-side -k postgres-operator-examples/kustomize/install/default


# Create the Postgres database cluster
kubectl create namespace ct
kubectl apply -n ct -f calltelemetry/kubernetes/postgres/ct-postgres.yaml

# kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v2.9/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# # Traefik Ingress Controller
# helm repo add traefik https://helm.traefik.io/traefik
# helm repo update
# kubectl create namespace traefik
# helm install -n traefik traefik traefik/traefik \
#   --set crds.enabled=true \
#   --set "additionalArguments[0]=--providers.kubernetesingress" \
#   --set "additionalArguments[1]=--log.level=DEBUG" \
#   --set "additionalArguments[2]=--entrypoints.websecure.http.tls" \
#   --set "additionalArguments[3]=--providers.kubernetescrd.namespaces=traefik" \
#   --set "additionalArguments[4]=--accesslog"

# helm install nginx-ingress ingress-nginx/ingress-nginx \
#   --namespace ingress-nginx \
#   --create-namespace \
#   --set controller.service.enabled=false

# Install the Call Telemetry Application

# Call Telemetry Repo
helm repo add ct_charts https://storage.googleapis.com/ct_charts/
helm repo update

# echo "Starting CallTelemetry deployment via Helm Chart"
cat <<EOF > ./custom_prod.yaml
# ct_prod.yaml
hostname: calltelemetry.local
environment: prod
primary_ip: $primary_ip
secondary_ip: $secondary_ip
cluster_ip_start: $admin_ip
cluster_ip_end:  $admin_ip
EOF

helm install -n ct ct ct_charts/stable-ha -f ./ct_prod.yaml

# Upgrading:
# helm upgrade -n ct ct ct_charts/stable-ha -f ./custom_values.yaml
echo "CallTelemetry Deployment complete"
