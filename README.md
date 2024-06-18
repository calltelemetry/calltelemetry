# Call Policy Engine and 911 Location Discovery for Cisco Callmanager

---

### Free [Community Edition](https://calltelemetry.com/getting-started)
More features available in licensed editions.

## Call Policy and CURRI API Engine
Learn more about what you can do with our [Call Policies](https://docs.calltelemetry.com/policies/introduction) to block calls, inject greetings, and add apps to calls.

### Call Policy Features - Free
- Simple call blocking features to block harassing callers or spam.
- Block up to 100 entries in the Global block list in the free version. Unlimited in any licensed version.
- Block calls based on calling Party, or a combination of calling and called party.
- Central Policy control across all Cisco Callmanager clusters in your environment.

### [Greeting Injection](https://docs.calltelemetry.com/policies/rule_greetings) - Free

- Greeting Injection using native Cisco Callmanager Announcement Media Resources.
- Injecting Announcements does not require Unity Connections, UCCX, UCCE, or CVP.
- Greeting Injection does not change your intended callflow.

### Licensed Call Policy Features
- Apps and Webhooks to any incoming call event - Send to CRMs, APIs, or build workflows to send complex alerts to teams for Emergency calls.
- Realtime Spam and Call Reputation scoring via TrueSpam API. Block, Rename, or Redirect calls based on a score 0-100.
- [Watch Lists and Triggers](https://docs.calltelemetry.com/policies/watch-lists/overview.html) to monitor and send email alerts in your environment for suspciious activity and call volume spikes. You can comment on, Block, or Ignore Watch List numbers.
- [Call Blocking API](https://docs.calltelemetry.com/mcid/block-list-api) for bulk call block management.
- Self Care Portal for Users
  - Users can manage their own call history and block list.
  - [Jabber Portal](https://docs.calltelemetry.com/mcid/jabber) for Cisco Jabber users to see history and block calls.
  - [Phone XML Portal](https://docs.calltelemetry.com/mcid/phone-xml-service) for Cisco IP Phone users to see history and block calls.
  - One click [MCID softkey](https://docs.calltelemetry.com/mcid/user_mcids) to block calls.

Learn more about [Call Blocking](https://docs.calltelemetry.com/mcid/intro) tools available in Call Telemetry.

#### [Call Apps and Event Webhooks](https://docs.calltelemetry.com/policies/call-apps)
- TrueSpam API for realtime caller spam robocall score, with actions to block call, redirect, or rename.
- CSV Lookup to locate subnets for location data - Locate phones in MRA, VPN, or Site lists.
- ICMP Traceroute to locate the last hop for location data
- Send data via Email or SMS to any destination
- XML SOAP web lookup App for querying APIs
- Share realtime data via webhook to any third party API.
- Need another App? [Contact Us](mailto:jason@calltelemtry.com) to build a custom app for your needs.
#### Build your own CRM Connectors
- Change Calling and Called Names, creating a simple CRM connection for Cisco Callmanager.
- Lookup and modify Caller ID via [Webhook CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-webhook) or [PostgreSQL CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-postgresql)


## [Phone Dashboard and Remote Control](https://docs.calltelemetry.com/realtime/phone-dashboard-reports) - Free (with Limits)
- Reports showing all details, serial, and CDP and LLDP Switch Neighbor and port for every phone.
- Report on the Firmware Version of all phones
- **International Support** We support ALL Cisco Callmanager Locales and Phone Languages, not just English.
- Report on the Hardware Version V03 / V04 etc, if you are preparing for a Webex Calling Migration
- Search across any phone field
- Export all or selected phone data
- Remote Control with Live Streaming Screen View of any phone
- Remote Factory Reset Cisco IP Phones

Free version limited to 1,000 random phones, and 7 days of registration report data.


## [CDR Reports](https://docs.calltelemetry.com/cdr/reporting) - Free (with Limits)
- Free SFTP server for CDR processing
- Decodes all Cisco CDR fields, not just epoch timestamps.
- Simple and Advanced reports for quick troubleshooting.
- Low Duration Call Report CDR Anlaytics to find spam robocallers

Free version limited to 7 days of CDR data.

## [911 Alerts and Emergency Features](https://docs.calltelemetry.com/e911) - Licensed Feature
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

## [Missed Call Alerts and Notifications](https://docs.calltelemetry.com/missed-call/intro) - Licensed Feature
- Missed call alerts to Email or Webex App
- Auto synchronization and provision of all Cisco Callmanager users nightly
- Add prefix to calling party to normalize outbound callback
- Lookup name and match Caller ID to internal callers
- Bulk import of users if you don't want to sync.
[Learn more about Missed Calls](https://docs.calltelemetry.com/missed-call/intro)

## [CDR Webhooks](https://docs.calltelemetry.com/cdr/webhooks) - Licensed Feature
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


---

Visit the [Latest Release Notes](https://docs.calltelemetry.com/changelog) full release notes.
