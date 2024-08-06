# Creating a Lab Instance

This document will walk through the steps to create a lab instance for Call Telemetry. The instance will be compeletely isolated from the production instance in a difference namesapce, including using a different Postgres cluster.

## Create Dev Namespace

```bash
kubectl create namespace ct-dev
```


### Build the Dev SQL Cluster

```bash
kubectl apply -n ct-dev -f postgres-operator-examples/kustomize/postgres/ct-postgres
```

### Prep Helm Chart values

```bash
cat <<EOF > ./custom_dev.yaml
# ct_dev.yaml
environment: dev
primary_ip: 192.168.123.100/32
secondary_ip: 192.168.123.101/32
admin_ip: 192.168.123.102/32
EOF
```

### Install Dev Helm Chart

```bash
helm install -n ct-dev ct ct_charts/stable-ha -f ./ct_dev.yaml
```

# Check Certificate Expiry and Reset

```bash
openssl s_client -connect localhost:6443 -showcerts < /dev/null 2>&1 | openssl x509 -noout -enddate
# sudo rm /var/lib/rancher/k3s/server/tls/dynamic-cert.json
sudo kubectl --insecure-skip-tls-verify=true delete secret -n kube-system k3s-serving
# sudo rm -rf /var/lib/rancher/k3s/server/tls/*.crt
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
```
