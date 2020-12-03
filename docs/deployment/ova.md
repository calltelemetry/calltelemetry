Download the OVA and import to Vmware.

Requirements:

* 2 vCPU  
* 4GB RAM  
* 10GB Disk Space (OVA currently requests 100GB)

<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-040.ova">Download Latest OVA Appliance (3.5Gb)</a>

OS Details
```
Centos
IP: DHCP
Username: centos
Password: centos
```

### First Login
It will bootup and grab a DHCP address, and print that on the main bootup screen.
Just open http://IPADDRESS and create a new login(signup).

Each user is assigned their own private Organizaiton by default. No data is shared between users unless the user is invited to the Organization.
Visit the [Organization Page](/features/organizations)  to learn more.


### Static IP
Changing the IP is standard CentOS 8.0 processes. I've used the "nmtui" CLI utility in my lab testing to assign static IPs.