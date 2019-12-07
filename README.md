# Simple and Scalable Call Blocking
Docker Images loaded with SFTP, PostreSQL, Elixir, a SIP Server, and CDR Parser - all working together to block calls.
# Features
## CURRI Policy Routing API server which can apply to any Phone, Route Pattern, or Translation Pattern, even over multiple CUCM Clusters.
## WebUI to enter blocked calls manually, and view events.
## CDR Parsing of Malicious Caller ID calls to block list - users just press the MCID softkey to add a call to the block list.
## SIP Transfer for users to transfer bad calls into, which adds to the block list.
## Full CDR decoding of every field per Cisco CDR Guide.
## Many more features coming.

## On-Prem Installation Guide

### Install Docker and Docker Compose for your OS of choice
Install Docker
https://docs.docker.com/v17.09/engine/installation/
Install Docker-Compose
https://docs.docker.com/compose/install/

Unoffical Guide that looks concise and helpful for Linux
https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=94798094

Assuming you can run these two commands - you are good to proceed.
```
docker --version
docker-compose --version
```

### Check your Port 22 for CDR SFTP
I use port 22 for Secure FTP (SFTP) transfer of CDR records. If you host on a linux OS, you probably already use port 22. The SFTP service onboard the container is locked down to the container, with no shell access, and the login is fully integrated with the web interface. If you login to the web page with admin@example.com - use the same username and password on the SFTP service.
I designed the service on Kubernetes, which does not need port 22. For now, change your host port to any other port for SSH access like this
```
vi /etc/ssh/sshd_config
```
edit port from 22 to 2222
save and restart.

### Launch the Web App (Elixir) and the Database (Postgres)
Clone the on-premise github repo. 

``` bash
git clone https://github.com/calltelemetry/calltelemetry.git
cd calltelemetry
docker-compose up (-d for daemon mode)

```
 
Once completed, you can login to CallTelemetry at http://yourIP:4000

Username: admin@example.com

Password: admin

Since you are running it locally inside Docker, the CURRI API URL will only know itself as localhost. So when you copy and paste the URL into Callmanager, update the IP to your host's IP Address.

#### That's it. Now go block some calls!
