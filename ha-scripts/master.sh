#!/bin/bash
export NODES=3
export cpus_per_api=1
# These are the two primary Virtual IPs for the CURRI API
export primary_ip="192.168.0.235"
export secondary_ip="192.168.0.236"
# This is a pool of IPs for Traefik Controller
export cluster_ip="192.168.0.237"
# Note: This sets the PostreSQL master user. It should be changed for production use.
export DB_PASSWORD="calltelemetry"
export INSTALL_K3S_CHANNEL=stable
export K3S_KUBECONFIG_MODE="0644"
# Note: This token is a preshared-key shared between the cluster. It should be changed for production use.
export K3S_TOKEN="calltelemetry"

# Nothing below this needs to be edited
curl -sfL https://get.k3s.io | sh -s server --cluster-init --no-deploy traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

# Install Traefik
/snap/bin/helm repo add traefik https://helm.traefik.io/traefik
/snap/bin/helm repo update
/snap/bin/helm install traefik traefik/traefik --set service.annotations."metallb\.universe\.tf\/address-pool"="default" --set deployment.replicas=3

echo "Preparing to Install CrunchyData PostgreSQL Operator"
/snap/bin/kubectl create namespace pgo
/snap/bin/kubectl apply -f https://raw.githubusercontent.com/CrunchyData/postgres-operator/v4.5.1/installers/kubectl/postgres-operator.yml
cat <<EOF > ~/.bashrc
export PGOUSER="${HOME?}/.pgo/pgo/pgouser"
export PGO_CA_CERT="${HOME?}/.pgo/pgo/client.crt"
export PGO_CLIENT_CERT="${HOME?}/.pgo/pgo/client.crt"
export PGO_CLIENT_KEY="${HOME?}/.pgo/pgo/client.key"
export PGO_APISERVER_URL='https://127.0.0.1:8443'
export PGO_NAMESPACE=pgo
EOF
source ~/.bashrc

echo "Installing PGO Operator - Wait for approximately 3 minutes for it to complete"
sleep 180

echo "Installing CrunchData PGO Client"
curl -s https://raw.githubusercontent.com/CrunchyData/postgres-operator/v4.5.1/installers/kubectl/client-setup.sh > ./client-setup.sh
chmod +x ./client-setup.sh
./client-setup.sh
ls -la ~/.pgo/pgo
sudo cp ~/.pgo/pgo/pgo /usr/local/bin
/snap/bin/kubectl port-forward -n pgo svc/postgres-operator 8443:8443 &
sleep 3
echo "Installing Postgres Cluster + Replicas, will take a moment to complete"
/usr/local/bin/pgo create cluster -n pgo ctsql -d calltelemetry_prod --password-superuser="calltelemetry"

echo "Scaling DNS in Kuberentes to match node count"
/snap/bin/kubectl scale deployment.v1.apps/coredns --replicas=$NODES -n kube-system

echo "Starting CallTelemetry deployment via Helm Chart"
cat <<EOF > ./custom_values.yaml
# ct_values.yaml
db_password: $DB_PASSWORD
web_replicas: $NODES
primary_ip: $primary_ip
secondary_ip: $secondary_ip
cluster_ip_start: $cluster_ip
cluster_ip_end: $cluster_ip
web:
  cpus: $cpus_per_api
  imagePullPolicy: IfNotPresent
  replicas: $NODES
EOF
/snap/bin/helm repo add ct_charts https://storage.googleapis.com/ct_charts/
/snap/bin/helm repo update
/snap/bin/helm install ct ct_charts/stable-ha -f ./custom_values.yaml
echo "CallTelemetry Deployment complete"