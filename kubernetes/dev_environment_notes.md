# Install Metallb
kubectl create namespace metallb-system
helm install -n metallb-system metallb metallb/metallb --set crds.validationFailurePolicy=Ignore

# Prep Dev Namespace

kubectl create namespace ct-dev
## Add dev user and dev db
```
    - name: calltelemetry-dev
      databases:
        - calltelemetry_dev
      options: "SUPERUSER"
```

vi postgres-operator-examples/kustomize/postgres/postgres.yaml
kubectl apply -k postgres-operator-examples/kustomize/postgres/

kubectl -n postgres-operator get secret hippo-pguser-calltelemetry -o json  | jq 'del(.metadata["namespace","creationTimestamp","resourceVersion","selfLink","uid","ownerReferences", "managedFields"])'  | kubectl apply -n ct -f -


kubectl -n postgres-operator get secret hippo-pguser-calltelemetry-dev -o json  | jq 'del(.metadata["namespace","creationTimestamp","resourceVersion","selfLink","uid","ownerReferences", "managedFields"])'  | kubectl apply -n ct-dev -f -

cat <<EOF > ./custom_prod.yaml
# ct_dev.yaml
environment: dev
primary_ip: 192.168.123.100/32
secondary_ip: 192.168.123.101/32
admin_ip: 192.168.123.102/32
EOF
helm install -n ct ct ct_charts/stable-ha -f ./ct_dev.yaml
