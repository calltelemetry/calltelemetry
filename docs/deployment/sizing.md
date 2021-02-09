## Sizing Guide
CallTelemetry VMs are sized by cpu and call volume. 

After much testing, 100 calls per CPU thread per second is a good guide for sizing. This varies based on the hardware you provide.

The OVA as released, with 2 vCPU, should handle 200 calls/second in under 20ms 95th precentile on most any machine. If you double vCPUs, performance doubles.

If you are only inspecting a translation pattern inbound and oubound, then 500-700 new call requests sustained per second is sufficient for most all customers.
Concurrent calls do not matter, only new events.

Stress testing on 0.4.1:
## 2019 Macbook Pro - Vmware Fusion, 0.4.1 OVA.
* 2 vCPU Threads - 200/calls/second - 21ms.
* 4 vCPU threads - 400/calls/second - 21ms.
* 6 vCPU threads - 550/calls/second - 21ms. 
* 8 vCPU Threads - 600/calls/second - 21ms.
* 10+ vCPU Threads - 700/calls/second. Virtualization operations slow down the maxium potential. Natively I can reach 1300/calls/second on the same system. Further optimization is being explored - the system can handle more in bursts, but this stress testing is purely a constant load test.
* Average 100/calls/second per vCPU using OVA model.
* Max 700/calls/second

## HP EliteDesk G2 Mini running ESXi 6.7
* i5-6500T 4 core, 32GB DDR3, nvme drive.
* Vmware ESXi 6.7SU1
* 3 VMs in a Kubernetes Cluster - Each VM ran on 1 core.
* Peak Load - 300/calls/second, 61ms 95th percentile. 3 Cores allocated to Call Processing.
* 100/calls/second per vCPU even in Kuberentes model, on a modest consumer desktop.
* Max 300/calls/second in this setup. I have more machines on order to test more nodes in the cluster.

The above testing was on consumer grade hardware, enterprise grade hardware should perform even better. I will be gathering more information on server hardware in the future.

If you need failover or scaling beyond cores in a single node, choose [Kubernetes](k8s.md)
