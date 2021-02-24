Download the OVA and import to Vmware. You are running the entire CallTelemetry platform on-premise.

As built below in the deafult template, it should service around 200/calls/second.

!!! note "Need more? Give it 8 cores to hit 700/calls/second. More than that? See the Enterprise HA Clustering."

Requirements:

* 2 vCPU 
* 4GB RAM  
* 60GB Disk Space

<a href="https://storage.googleapis.com/ct_ovas/CallTelemetry-stable.ova">Download Latest OVA Appliance (1.12Gb)</a>

OS Details
```
CentOS 8.3
IP: DHCP
Username: calltelemetry
Password: calltelemetry
```

### First Login
It will bootup and grab a DHCP address, and print that on the console.
Just open a web browser to http://IPADDRESS and create a new login(signup).

Each user is assigned their own private Organizaiton by default. No data is shared between users unless the user is invited to the Organization.
Visit the [Organization Page](/features/organizations)  to learn more.
### Static IP
Changing the IP is standard CentOS 8.0 processes. I've used the "nmtui" CLI utility in my lab testing to assign static IPs.

### Change the OS Password
Good practice, change the password, it's one command.
```
passwd
```