#!/bin/bash

export NODES=3
# These are the two primary Virtual IPs for the CURRI API, and Admin IP
export primary_ip="192.168.123.231"
export secondary_ip="192.168.123.232"
export admin_ip="192.168.123.233"

# uninstall:
# /usr/local/bin/k3s-uninstall.sh

# Install K3s on the master
# cluster-init means master
# token is a preshared key among the k3s nodes for HA
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE=0644 K3S_TOKEN=calltelemetry sh -s server --cluster-init --disable traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

echo "Preparing to Install CrunchyData PostgreSQL Operator"
# Reference:
# https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/high-availability/
git clone https://github.com/CrunchyData/postgres-operator-examples.git
# Explore sample config from call telemetry repo /ha-scripts

# Install the Crunchy Postgres K8s Operator
kubectl apply -k postgres-operator-examples/kustomize/install/namespace
kubectl apply --server-side -k postgres-operator-examples/kustomize/install/default
# Create the Postgres database
# kubectl apply -k postgres-operator-examples/kustomize/postgres

# This file will create a database with 3 replicas.

cat << EOF > ./postgres-operator-examples/kustomize/postgres/postgres.yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: hippo
spec:
  users:
    - name: calltelemetry
      databases:
        - calltelemetry_prod
      options: "SUPERUSER"
    - name: calltelemetry-dev
      databases:
        - calltelemetry_dev
      options: "SUPERUSER"
  image: registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-14.5-0
  postgresVersion: 14
  instances:
    - name: instance1
      replicas: 3
      dataVolumeClaimSpec:
        accessModes:
        - "ReadWriteOnce"
        resources:
          requests:
            storage: 1Gi
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                postgres-operator.crunchydata.com/cluster: hippo
                postgres-operator.crunchydata.com/instance-set: instance1
  backups:
    pgbackrest:
      image: registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest:ubi8-2.40-0
      repos:
      - name: repo1
        volume:
          volumeClaimSpec:
            accessModes:
            - "ReadWriteOnce"
            resources:
              requests:
                storage: 1Gi
EOF

kubectl apply -k postgres-operator-examples/kustomize/postgres

# Add replcias to kustomize/postgres/yaml if desired, re-run kustomize.

# Create pgo user
# add spec in kustomize file
# vi kustomize/postgres/postgres.yaml
# specs:
#   users:
#     - name: calltelemetry
#       databases:
#         - calltelemetry_prod
#       options: "SUPERUSER"
# kubectl apply -f kustomize/postgres/postgres.yaml
# clone secret to default namespace
# kubectl delete secret hippo-pguser-calltelemetry
sudo yum install -y jq
# Copy secret to the ct namespace for database access
kubectl create namespace ct
kubectl -n postgres-operator get secret hippo-pguser-calltelemetry -o json  | jq 'del(.metadata["namespace","creationTimestamp","resourceVersion","selfLink","uid","ownerReferences", "managedFields"])'  | kubectl apply -n ct -f -

echo "Scaling DNS in Kuberentes to match node count"
/snap/bin/kubectl scale deployment.v1.apps/coredns --replicas=$NODES -n kube-system

# echo "Installing MetalLB" --- part of the stable-ha charts, not necessary.
# helm repo add metallb https://metallb.github.io/metallb
# # 0.13 has breaking changes and outstanding issues
# helm install metallb metallb/metallb --version 0.12.1
# helm install metallb bitnami/metallb

helm repo add ct_charts https://storage.googleapis.com/ct_charts/
helm repo update
# echo "Starting CallTelemetry deployment via Helm Chart"
cat <<EOF > ./custom_prod.yaml
# ct_prod.yaml
environment: prod
primary_ip: $primary_ip
secondary_ip: $secondary_ip
cluster_ip_start: $admin_ip
cluster_ip_end: $admin_ip
EOF
helm install -n ct ct ct_charts/stable-ha -f ./ct_prod.yaml

# Upgrading:
# helm upgrade -n ct ct ct_charts/stable-ha -f ./custom_values.yaml
# Installing without a file:

# helm install ct ct_charts/stable-ha --set primary_ip="$primary_ip" --set secondary_ip="$secondary_ip" --set cluster_ip_start="$admin_ip"
echo "CallTelemetry Deployment complete"
