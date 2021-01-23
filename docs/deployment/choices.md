## Single Node
Easiset to demo in a lab, boots, DHCP, and sign in. 
You can go production with it too, it will automatically start up all service on reboot.
Make sure to size it correctly to the call volume you expect, by default it only requests 2 vCPU - about 100 calls/second.
An example PostgreSQL backup script is included in the folder.

* [OVA Appliance](ova.md)

## Multi Node HA
If you need to scale to multiple vCPU VMs for load balancing, or capacity, or failover - choose this.
You will get 2 Virtual IPs floating among 3+ nodes, with PostgreSQL replicas on each node. 
The CrunchyData PostgreSQL operator has a built in backup scheduler you can use for backups.

* [Cluster - Kubernetes](k3s.md)
