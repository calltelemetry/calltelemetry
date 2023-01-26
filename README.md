# Call Policy and 911 Location Discovery for Cisco Callmanager

---

## Free [Community Edition](https://calltelemetry.com/getting-started) with advanced features in paid editions.

# Realtime Call Policy Engine

## Alerts

- Realtime 911 Alerts.
- Discover phone details in realtime.
- Alerts can include CDP neighbor, Subnet, and Callmanager data.
- Email, SMS, MS Teams, Webex Teams support.
- Creates a Webex Teams Space for each rule alert, invites others, and allows you to collaborate as a team in the space for situational awareness of the call.

## Location Tools for Emergency Alerting.

- Discovery of CDP Neighbor, Subnet, and ICMP traceroute.
- 911 Location Manager: Subnet, Switch, Port.
- Query APIs for more location data from phone data.
- Meraki Location Sync for CDP neighbors and pulls switch physical address and notes.
- 911 QR Code Location Tool for network drop wire mapping.

## Call Policy Engine

- Inbound & Outbound call block rules to block harassing callers or spam.
- Realtime Robocall Spam protection via TrueSpam
- Processed MCID triggers so that users press one button to block calls.
- Add Apps and Webhooks to any call event.
- Self Service Blocking via Jabber custom tab
- Access Phone details, CDP neighbor data, and Subnet in your alerts/webhooks.
- Use Google Text to Speech to generate announcements and upload automatically across all CUCM Clusters (beta)
- Change Calling / Called Names and Numbers
- Central Policy API across all CUCMs in your environment.

## Apps
- TrueSpam API for realtime caller spam robocall score, with actions to block call, redirect, or rename.
- Postgres Lookup of Caller ID
- Webex Teams Space with live call data
- CSV Lookup to locate subnets for location data - Locate phones in MRA, VPN, or Site lists.
- ICMP Traceroute to locate the last hop for location data
- Send data via Email or SMS to any destination
- XML SOAP web lookup App for querying APIs
- Share realtime data via webhook to any third party API.

## Greeting Injection

- Greeting Injection using native CUCM Announcements
- Works on Internal or External calls
- Injecting Announcements does not require Unity Connections or UCCX.
- Greeting Injection does not change your intended callflow, even the CDR stays the same!

## Missed Call Alerts
- Missed call alerts to email or Webex App
- Auto synchronization and provision of all CUCM AXL users nightly
- Add prefix to calling party to normalize outbound callback
- Lookup name and match Caller ID to internal callers
- Bulk import of users if you don't want to sync.
# Host it any way you choose

- [Vmware OVA Appliance](https://docs.calltelemetry.com/deployment/ova.html)
- [Docker](https://hub.docker.com/r/calltelemetry/web)
- [Kubernetes](https://docs.calltelemetry.com/deployment/k3s.html)
- [Multinode HA Kubenretes failover](https://docs.calltelemetry.com/deployment/k3s.html)
# 100% Private and Secure

- On-premise or your cloud. Doesn't matter.
- No tracking, analytics, or call home features.
- Role based access support for multiple team members.
- CURRI / ECC TLS support, upload your own certificate.
- Even Runs isolated and internet air gapped.

## Remote Control IP Phones

- Remote Control with Live Streaming Screen View of any phone
- ITL Reset

## Phone Inventory Reports

- Reports showing all details, serial, and CDP LLDP Neighbor and port for every phone
- Report on the Hardware Version V03 / V04 etc, if you are preparing for a Webex Calling Migration
- Search across any phone field
- Export all or selected phone data

## CDR Troubleshooting

- Built in SFTP server for CDR processing
- Decodes all CDR fields
- Simple reports for quick troubleshooting.
- CDR Anlaytics to find spam robocallers


---

Visit the official [Release Notes](https://docs.calltelemetry.com/changelog/) full release notes.
