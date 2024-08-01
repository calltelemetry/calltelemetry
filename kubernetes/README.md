
# Call Telemetry Deployment Guide

This guide provides detailed instructions for setting up and deploying the Call Telemetry application using Kuberenetes with load balancing an a HA PostgreSQL Cluster.

Kubernetes is free to use on your own, and support is available please context [Support](mailto:jason@calltelelemetry.com) for more information.

## Prerequisites

Before beginning the installation, ensure you have the following requirements. A 3 node cluster will need 7 IP Addresses on the same subnet to complete the install.

- **Node IPs**: Multiple nodes as typically installed for a highly available cluster. 3 nodes are recommended for a production environment. These are standard IP addresses for the OS.
- **Primary Virtual IP**: The Virtual IP address of the Primary CURRI API service.
- **Secondary Virtual IP**: The Virtual IP address of the Secondary CURRI API service.
- **Admin Virtual IP**: The Virtual IP address used by the Call Telemetry Management API.
- **Management Virtual IP**: The Virtual IP addresses used for the Call Telemetry Management Web Page.
- **K3S Token**: A pre-shared key among K3s nodes for authentication. You can set it now, or get it post-install from the primary node with `sudo cat /var/lib/rancher/k3s/server/node-token`.

## Installation Steps

### OS Preparation

This step configures the firewall, and installs some tools needed for managing Kubernetes.

### Supported OS Versions

- AlmaLinux 9.x
- RHEL 9.x
- CentOS Stream 9.x

```bash
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
wget https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_x86_64.tar.gz
tar -xzf k9s_Linux_x86_64.tar.gz
sudo mv k9s /usr/local/bin
mkdir ~/.k9s
rm -rf k9s*

# Install GIT
sudo dnf install -y git
```

### K3s Installation

**K3s** is a lightweight Kubernetes distribution designed for easy installation and operation of Kuberenetes.

#### Setting Up the Primary Node

1. **Install K3s**
   Install K3s on the primary node. Note the token value, which is hashed into the shared cluster secret value.

   ```bash
   export K3S_TOKEN="calltelemetry"
   curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE=0644 sh -s server --cluster-init --disable traefik --disable servicelb
   ```

   This command initializes the K3s server, disables Traefik (a default ingress controller), and the default service load balancer.

2. **Configure Kubectl**
   Set up `kubectl`, the command-line tool for interacting with the Kubernetes cluster:

   ```bash
   mkdir -p ~/.kube
   sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
   ```

#### Optionally Setting Up Secondary Nodes

3 Nodes is typical for a Kubenretes cluster, but you can skip this step and just run a single node.

1. **Install K3s on Secondary Nodes**
   Join secondary nodes to the K3s cluster. Note the token value, and the primary node IP address.

   ```bash
   export primary_ip="192.168.123.156"
   export K3S_TOKEN="calltelemetry"
   sudo curl -sfL https://get.k3s.io | K3S_URL="https://$primary_ip:6443" K3S_KUBECONFIG_MODE=0644 sh -s server --disable traefik --disable servicelb
   mkdir -p ~/.kube
   sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
   ```

2. **Scale DNS Pods**
   Adjust DNS pod replicas to match the number of total nodes. This helps with failover.

   ```bash
   kubectl scale deployment.v1.apps/coredns --replicas=3 -n kube-system
   ```

### MetalLB Installation for Load Balancing

**MetalLB** is a load balancer implementation for bare metal Kubernetes clusters, enabling external access to services.


1. **Install MetalLB Using Helm**
   Helm is a package manager for Kubernetes, and it simplifies the deployment of applications:

   ```bash
   kubectl create namespace metallb-system
   helm repo add metallb https://metallb.github.io/metallb
   helm install -n metallb-system metallb metallb/metallb
   ```

### CrunchyData PostgreSQL Operator Installation

The **CrunchyData PostgreSQL Operator** automates PostgreSQL database cluster deployment, management, and monitoring in Kubernetes.

1. **Install PostgreSQL Operator and CRDs**

   ```bash
   kubectl create namespace postgres-operator
   git clone https://github.com/CrunchyData/postgres-operator-examples.git
   kubectl apply --server-side -k postgres-operator-examples/kustomize/install/default
   ```

2. **Create CT PostgreSQL Database Cluster**

   ```bash
   kubectl create namespace ct
   kubectl apply -n ct -f calltelemetry/kuberentes/postgres/ct-postgres.yaml
   ```

### Call Telemetry Application Deployment

1. **Add Call Telemetry Helm Repository**

   ```bash
   helm repo add ct_charts https://storage.googleapis.com/ct_charts/
   helm repo update
   ```

2. **Create Custom Configuration File**
   Customize deployment parameters such as hostname and IPs:

   ```bash
   cat <<EOF > ./ct_prod.yaml
   hostname: calltelemetry.local
   environment: prod
   primary_ip: 192.168.123.203
   secondary_ip: 192.168.123.204
   cluster_ip_start: 192.168.123.205
   cluster_ip_end: 192.168.123.205
   admin_ip: 192.168.123.206
   management_ip: 192.168.123.207
   EOF
   ```

3. **Deploy Using Helm**
   Helm is used to deploy the application with the specified configuration:

   ```bash
   helm install -n ct ct ct_charts/stable-ha -f ./ct_prod.yaml
   ```

## Upgrading the Application

To upgrade the Call Telemetry application, use:

```bash
helm upgrade -n ct ct ct_charts/stable-ha -f ./ct_prod.yaml
```

## Troubleshooting

### Uninstall K3s

To uninstall K3s, use:

```bash
/usr/local/bin/k3s-uninstall.sh
```
