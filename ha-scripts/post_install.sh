#!/bin/bash
echo "Scaling DNS in Kuberentes"
/snap/bin/kubectl scale deployment.v1.apps/coredns --replicas=3 -n kube-system

echo "Scaling SQL Replica to this node"
/usr/local/bin/pgo scale -n pgo ctsql --no-prompt --replica-count=2
