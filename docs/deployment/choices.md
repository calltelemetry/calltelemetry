??? note "Call Capacity Sizing Guide"
    0.4.0 can process about 35-50/new call requets per second PER CORE under 50ms. This depends on the hardware you provide the system.

    For example:

    * i5 4 core Laptop - 150/calls/second sustained.
    * i9 8 core Macbook - 350/calls/second sustained.

    You ca provide more cores to the OVA download for more capacity. If you need failover or scaling beyond cores in a single node, choose [Kubernetes](k8s.md)
        

## Single Node
Easiset to demo in a lab, boots, DHCP, and sign in. 
You can go production with it too, it will automatically start up all service on reboot.
Make sure to size it correctly to the call volume you expect, by default it only requests 2 vCPU - about 100 calls/second.
An example PostgreSQL backup script is included in the folder.

* [OVA Appliance](ova.md)

## Multi Node HA (BETA)
If you need to scale to multiple vCPU VMs for load balancing, or capacity, or failover - choose this.
You will get 2 Virtual IPs floating among 3+ nodes, with PostgreSQL replicas on each node. 
The CrunchyData PostgreSQL operator has a built in backup scheduler you can use for backups.

* [Cluster - Kubernetes](k3s.md)
