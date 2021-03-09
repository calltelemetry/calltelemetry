If you have any questions, please contact jason@calltelemetry.com.
## Single Node - 
Easiset to deploy. Boots up, grabs DHCP, and hit the HTTP login screen. 
Production ready, it will automatically start up all service on reboot.
Make sure to size it correctly to the call volume you expect, by default it only requests 2 vCPU - about 200 calls/second sustained load. Add more cores, and it can scale to 700/calls/second inspected.
An example PostgreSQL backup script is included in the folder.

* [OVA Appliance](ova.md)

## Multi Node HA Cluster
If you need to scale to multiple vCPU VMs for load balancing, or capacity, or failover - choose this.
You will get 3 Virtual IPs floating among 3+ nodes, with PostgreSQL replicas on each node. 
The CrunchyData PostgreSQL operator has a built in backup scheduler you can use for backups.

* [Cluster - Kubernetes](k3s.md)
