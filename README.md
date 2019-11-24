# CallTelemetry
## Scalable Call Action Platform for Cisco Callmanager

## Solutions
### Robo / Spam / Call Blocking across all Callmanagers in your environment
* Call Blocking Control using Cisco Unified Policy Routing API / Curri API / External Call Control Profile. One URL to paste into Callmanager and you can apply the ECC profile to any Trunk, Route Pattern, Translation, or Directory Number, even to multiple CUCM Clusters to have complete call enforcement.
### CDR Integration - coming soon in 0.3.x Train
* Process Call Detail Records in realtime for actions.
* Trigger Malicious Caller-ID (MCID), including alerts and automatically blacklisting the caller.

## Post a request in Issues for what you want next. 

# Cloud or On-Prem - Doesn't matter.
Want Cloud? Visit www.calltelemetry.com
Want an On-Premise solution? Follow the guide below, nothing is shared with the cloud.

## On-Prem Guide

### Install Docker and Docker Compose for your OS of choice
https://docs.docker.com/v17.09/engine/installation/

https://docs.docker.com/compose/install/

### Launch the Web App (Elixir) and the Database (Postgres)
Clone the repo or download the docker-compose.yml file.


``` bash
git clone https://github.com/calltelemetry/calltelemetry.git
cd calltelemetry
docker-compose up -d

```
 

### Run DB Migrations Provision the initial On-Prem Admin user.
The onprem_admin seed creates admin@example.com with a password of admin. You can change them inside the web app.

``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Release.migrate

docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Seeds.onprem_admin
```
Once completed, you can login to CallTelemetry at http://yourIP:4000

Username: admin@example.com

Password: admin

### Now go block some calls.
I am working on more content. For now, a full walkthrough of no config to blocking calls on a single phone is best seen in this video.

https://studio.youtube.com/video/q--jzdSkEDw/edit



# FAQ
### Licensing On-Prem
The Docker builds are unlimited while in Open Beta, and expires Feb 1, 2020. 
There will always be a free version, but licensing is not defined yet.
