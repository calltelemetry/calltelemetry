## Sizing Guide

### 100 new call inspections *per core* *per second* while under 15ms. 

The OVA is 2 vCPU, and hits 200-300 new calls insepctions *per second* in under 15ms, constant load, 95th percentile.

Scale the OVA to 8 vCPU and get 600+ call inspections *per second* in under 15ms.

*If you need to inspect more than 600 calls per second on a single box, let's talk - email me jason@calltelemetry.* 

!!! note "This is **new** events per second sustained stress testing, not concurrent calls active in the system. If you have call requests spikes above this rate, they can be easily handled momentarily."

In the event the system is overloaded, connections will be returned error with HTTP code 500, and calls will continue according to the ECCP profile setting default.

If you need failover or scaling beyond a single node, take a look at the Enterprise HA option[Kubernetes](k8s.md)
