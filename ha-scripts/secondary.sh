#!/bin/bash
# Edit this to be the primary node / any master node.
export primary_ip="192.168.0.148"
#his token is a preshared-key shared between the cluster. It should be changed for production use.
export K3S_TOKEN="calltelemetry"

# Nothing below this needs to be edited
export K3S_URL="https://$primary_ip:6443"
export INSTALL_K3S_CHANNEL=stable
export K3S_KUBECONFIG_MODE="0644"

# Install Master
curl -sfL https://get.k3s.io | sh -s server  --no-deploy traefik --disable servicelb
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

export PGOUSER="${HOME?}/.pgo/pgo/pgouser"
export PGO_CA_CERT="${HOME?}/.pgo/pgo/client.crt"
export PGO_CLIENT_CERT="${HOME?}/.pgo/pgo/client.crt"
export PGO_CLIENT_KEY="${HOME?}/.pgo/pgo/client.key"
export PGO_APISERVER_URL='https://127.0.0.1:8443'
export PGO_NAMESPACE=pgo

echo "Installing CrunchData PGO Client"
# wget https://raw.githubusercontent.com/CrunchyData/postgres-operator/v4.5.1/installers/kubectl/client-setup.sh
curl -s https://raw.githubusercontent.com/CrunchyData/postgres-operator/v4.5.1/installers/kubectl/client-setup.sh > ~/client-setup.sh
chmod +x ~/client-setup.sh
~/client-setup.sh
ls -la ~/.pgo/pgo
# ls -la /home/calltelemetry/.pgo/pgo
sudo cp ~/.pgo/pgo/pgo /usr/local/bin
/snap/bin/kubectl port-forward -n pgo svc/postgres-operator 8443:8443 &

echo "Scaling SQL Replica to this node"
/usr/local/bin/pgo scale -n pgo ctsql --no-prompt