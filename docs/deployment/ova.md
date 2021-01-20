Download the OVA and import to Vmware. 

As built below, it's good for about 100/calls/second.

Requirements:

* 2 vCPU 
* 4GB RAM  
* 60GB Disk Space

<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-040-slim.ova">Download Latest OVA Appliance (1.4Gb)</a>

OS Details
```
CentOS 8.3
IP: DHCP
Username: calltelemetry
Password: calltelemetry
```

### First Login
It will bootup and grab a DHCP address, and print that on the main bootup screen.
Just open a web browser to http://IPADDRESS and create a new login(signup).

Each user is assigned their own private Organizaiton by default. No data is shared between users unless the user is invited to the Organization.
Visit the [Organization Page](/features/organizations)  to learn more.


### Static IP
Changing the IP is standard CentOS 8.0 processes. I've used the "nmtui" CLI utility in my lab testing to assign static IPs.