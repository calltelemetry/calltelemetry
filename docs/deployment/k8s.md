## Kubernetes Charts
You can be Production Ready - 5 minutes

Just 5 minutes from Bare Ubuntu 18.0.4 VM to install a full Kubernetes Cluster + CallTelemetry and get to the login screen.
![k8s install](k8s-install.gif)  

    
### Run the script
Change your IP range

``` bash
sudo snap install microk8s --classic --channel=1.18/stable
sudo microk8s.enable dns storage helm3 metallb:192.168.123.170-192.168.123.171
sudo microk8s.helm3 repo add calltelemetry https://calltelemetry.github.io/calltelemetry/
sudo microk8s.helm3 repo update
sudo microk8s.kubectl create namespace calltelemetry
sudo microk8s.helm3 install calltelemetry --namespace=calltelemetry calltelemetry/stable

```

### Check that everything is online
```
demo@demo-VirtualBox:~$ sudo microk8s.kubectl get pod -n calltelemetry
NAME                             READY   STATUS    RESTARTS   AGE
calltelemetry-7dbcc5784f-vz5vv   1/1     Running   0          12m
```