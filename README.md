# Call Policy Engine and 911 Location Discovery for Cisco Callmanager

---

### Free [Community Edition](https://calltelemetry.com/getting-started)
More Advanced features in paid editions.

## [Call Policy](https://docs.calltelemetry.com/policies/introduction) Engine - Community Feature
- Simple call blocking features to block harassing callers or spam.
- Realtime Robocall Spam protection via TrueSpam Scoring.
- Add Apps and Webhooks to any incoming call event.
- Central Policy CURRI API across all Cisco Callmanagers in your environment.
- Access Phone details, CDP neighbor data, and Subnet in your alerts/webhooks.

### Premium Features
- Call Blocking API for bulk blocking management.
- Self Care Portal for Users
  - Users can manage their own call history and block list.
  - [Jabber Portal](https://docs.calltelemetry.com/mcid/jabber) for users to see history and block calls.
  - [Phone XML Portal](https://docs.calltelemetry.com/mcid/phone-xml-service) for phone users to see history and block calls.
  - Users can also press the [MCID softkey](https://docs.calltelemetry.com/mcid/user_mcids) to block calls.
[Learn more about Call Blocking](https://docs.calltelemetry.com/mcid/intro)

### [Greeting Injection](https://docs.calltelemetry.com/policies/rule_greetings) - Community Feature

- Greeting Injection using native Cisco Callmanager Announcements
- Injecting Announcements does not require Unity Connections or UCCX.
- Greeting Injection does not change your intended callflow.

## [Call Apps](https://docs.calltelemetry.com/policies/call-apps) - Premium Feature
- TrueSpam API for realtime caller spam robocall score, with actions to block call, redirect, or rename.
- CSV Lookup to locate subnets for location data - Locate phones in MRA, VPN, or Site lists.
- ICMP Traceroute to locate the last hop for location data
- Send data via Email or SMS to any destination
- XML SOAP web lookup App for querying APIs
- Share realtime data via webhook to any third party API.

### CRM Connectors
- Change Calling and Called Names, creating a simple CRM connection for Cisco Callmanager.
- Lookup and modify Caller ID via [Webhook CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-webhook) or [PostgreSQL CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-postgresql)

## [911 Call Alerts](https://docs.calltelemetry.com/e911) - Premium
- Realtime 911 Alerts with location data for Cisco IP Phones.
- Discover Cisco IP Phone details in realtime.
- Alerts can include CDP neighbor, Subnet, and Cisco Callmanager data.
- Notications for Email, SMS, MS Teams, and Webex Teams.
- Creates a Webex Teams Space for each rule alert, invites others, and allows you to collaborate as a team in the space for situational awareness of the call.

### Location Discovery Apps for Emergency Alerts

- Discovery of CDP and LLDP Netowrk Switch Neighbor, IP Subnet, and ICMP traceroute for use in call workflows.
- 911 Location Manager: Subnet, Switch, Port.
- Query APIs for more location data from Cisco IP Phone data.
- Meraki Location Sync for CDP neighbors and pulls switch physical address and notes.
- 911 QR Code Location Tool for network drop wire mapping.

## [Missed Call Alerts and Notifications](https://docs.calltelemetry.com/missed-call/intro) - Premium
- Missed call alerts to Email or Webex App
- Auto synchronization and provision of all Cisco Callmanager users nightly
- Add prefix to calling party to normalize outbound callback
- Lookup name and match Caller ID to internal callers
- Bulk import of users if you don't want to sync.
[Learn more about Missed Calls](https://docs.calltelemetry.com/missed-call/intro)

## [CDR Webhooks](https://docs.calltelemetry.com/cdr/webhooks) - Premium
Fire off a webhook for every call event in CDR matching multiple conditions. Include CDR data in the webhook payload.

## Multiple runtime options
Multiple OS options - CentOS 9 Stream, AlamaLinux, RHEL supported, or run your own containers.

Deployment options:
- [Vmware OVA Appliance](https://docs.calltelemetry.com/deployment/ova.html)
- [Docker](https://docs.calltelemetry.com/deployment/docker.html)
- [Kubernetes](https://docs.calltelemetry.com/deployment/k3s.html)
- [Multinode HA Kubenretes failover](https://docs.calltelemetry.com/deployment/k3s.html)

### Private and Secure
- Can run air gapped with no internet access.
- No tracking, analytics, or telemetry tracking features. (We don't track you or your data)
- Role based access support for multiple team members.
- Cisco CURRI API and Cisco Extended Call Control Profile TLS support

## [Phone Dashboard and Cisco IP Phone Remote Control](https://docs.calltelemetry.com/realtime/phone-dashboard-reports) - Community with limits
- Reports showing all details, serial, and CDP LLDP Neighbor and port for every phone
- Report on the Hardware Version V03 / V04 etc, if you are preparing for a Webex Calling Migration
- Search across any phone field
- Export all or selected phone data
- Remote Control with Live Streaming Screen View of any phone
- Remote Factory Reset Cisco IP Phones


## [CDR Reports](https://docs.calltelemetry.com/cdr/reporting) - Community with limits
- Free SFTP server for CDR processing
- Decodes all Cisco CDR fields, not just epoch timestamps.
- Simple and Advanced reports for quick troubleshooting.
- Low Duration Call Report CDR Anlaytics to find spam robocallers


---

Visit the [Latest Release Notes](https://docs.calltelemetry.com/changelog) full release notes.
