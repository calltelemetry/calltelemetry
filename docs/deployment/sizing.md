## Sizing Guide
0.4.0 can process about 35-50/new call requets per second Per Core under 50ms. This depends on the physical hardware you provide the system.

For example:

* i5 4 core Laptop - 150/calls/second sustained.
* i9 8 core Macbook - 350/calls/second sustained.

You ca provide more cores to the OVA download for more capacity. If you need failover or scaling beyond cores in a single node, choose [Kubernetes](k8s.md)