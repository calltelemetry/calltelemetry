## Sizing Guide

General Sizing: 100 new call inspections per core *per second* in under 15ms. 

The OVA is 2 vCPU, and hits 200-300 new calls insepctions *per second* in under 15ms, constant load, 95th percentile.

Scale the OVA to 8 vCPU and get 600+ call inspections *per second* in under 15ms.

If you need to inspect more than 600 calls per second on a single box, let's talk - email jason@calltelemetry. Configurations can reach 3,000 per second sustained volume on 8 cores, but you are probably better suited for the Enterprise Cluster mode.

This sizing guide is sustained **NEW** events per second, not concurrent calls active in the system. If you have call requests spikes above this, they can be easily handled momentarily @ 200-300 calls per second at the cost of some latency.

In the event the system is overloaded, connections will be returned error with HTTP code 500, and calls will continue according to the ECCP profile setting default.

If you need failover or scaling beyond a single node, choose the Enterprise HA option[Kubernetes](k8s.md)
