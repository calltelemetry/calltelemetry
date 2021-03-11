# Download Links
<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-stable.ova">Download 0.4.0 ("stable") OVA Appliance (1.1Gb)</a>

<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-041.ova">Download 0.4.1 ("beta") OVA Appliance (1.1GB)</a>

<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-042.ova">Download 0.4.2 ("beta" OVA Appliance (900MB)</a>

Download the OVA and import to Vmware. 

The default import template of 2 vCPUS will process 200 new call inspections/second.

!!! note "Need more? Allocate 8 cores to hit 700/calls/second. More than that? See the Enterprise HA Clustering."

Requirements:

* 2 vCPU 
* 4GB RAM  
* 60GB Disk Space

OS Details
```
CentOS 8.3
IP: DHCP
Username: calltelemetry
Password: calltelemetry
```

### First Login
It will bootup and grab a DHCP address, and display that on the console.
Just open a web browser to http://IPADDRESS and create a new login(signup).

Each user is assigned their own private Organizaiton by default. No data is shared between users unless the user is invited to the Organization.
Visit the [Organization Page](/features/organizations)  to learn more.
### Static IP
Changing the IP is standard CentOS 8.0 processes. I've used the "nmtui" CLI utility in my lab testing to assign static IPs.

### Change the OS Password
Good practice, change the OS password for calltelemetry - it's just one command.
```
passwd
```