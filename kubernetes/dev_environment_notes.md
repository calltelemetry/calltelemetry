# Install Metallb
kubectl create namespace metallb-system
helm repo add metallb https://metallb.github.io/metallb
helm install -n metallb-system metallb metallb/metallb --set crds.validationFailurePolicy=Ignore

# Create Dev Namespace

kubectl create namespace ct-dev
## Add dev user and dev db

```
cat << EOF > ./postgres-operator-examples/kustomize/postgres/postgres.yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: hippo-dev
spec:
  users:
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
                postgres-operator.crunchydata.com/cluster: hippo-dev
                postgres-operator.crunchydata.com/instance-set: instance1
  backups:
    pgbackrest:
      image: registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest:ubi8-2.40-0
      repos:
      - name: repo2
        volume:
          volumeClaimSpec:
            accessModes:
            - "ReadWriteOnce"
            resources:
              requests:
                storage: 1Gi
EOF
```

kubectl apply -k postgres-operator-examples/kustomize/postgres/

kubectl -n postgres-operator get secret hippo-pguser-calltelemetry-dev -o json  | jq 'del(.metadata["namespace","creationTimestamp","resourceVersion","selfLink","uid","ownerReferences", "managedFields"])'  | kubectl apply -n ct-dev -f -

cat <<EOF > ./custom_dev.yaml
# ct_dev.yaml
environment: dev
primary_ip: 192.168.123.100/32
secondary_ip: 192.168.123.101/32
admin_ip: 192.168.123.102/32
EOF

helm install -n ct-dev ct ct_charts/stable-ha -f ./ct_dev.yaml
