# Call Policy Engine, and Realtime Tool Suite for Cisco Callmanager

---
[Latest Version and Release Notes](https://docs.calltelemetry.com/releases)

Free Community License includes these core features:

- Policy Engine with Call Blocking
- Unlimited Permit and Block Rules
- Unlimited Policies
- Greeting Injection
- Global Block List for up to 100 numbers
- Modify Calling and Called Party Numbers and Calling Names
- Phone Dashboard and Neighbor discovery up to 1000 phones
- Phone Remote Control
- Basic CDR Reports up to 7 days
- 1 Administrator
- 1 Callmanager Cluster

Additional features are enabled with a [paid license](https://calltelemetry.com/#pricing).

## Multiple Deployment options

- [Vmware OVA Appliance](https://docs.calltelemetry.com/deployment/ova.html)
- [Bring your own OS](https://docs.calltelemetry.com/deployment/docker.html)
- [HA Cluster](https://docs.calltelemetry.com/deployment/k3s.html)

### Private and Secure

- Secure - No internet required. Air gap support.
- Private - No user tracking or analytics.
- Teams Support - Multi-user Role Based access support based on features.
- Encryption Support - TLS Administration, Secure FTP, and Cisco CURRI API TLS support

## Call Policy and CURRI API Engine

[Use Call Policies](https://docs.calltelemetry.com/policies/introduction) to block calls, inject greetings, and add apps to calls.

### Call Policy Features

- Use a [Global Block list](https://docs.calltelemetry.com/call-block/global-call-block-list) to block calls across multiple clusters.
- Block calls based on calling Party, or a combination of calling and called party.
- Unlimited Call Routing Rules - Block, Permit, Change Caller IDs, Translate / Redirect, or Inject Greetings.
- Multiple Cluster Support - Central Policy control across all Cisco Callmanager clusters in your environment.
- Apps and [Webhooks](https://docs.calltelemetry.com/policies/apps/crm-integration-webhook) to any incoming call event - Send to CRMs, APIs, or build workflows to send complex alerts to teams for Emergency calls.
- Realtime Spam and [Call Reputation scoring](https://docs.calltelemetry.com/policies/truespam_filtering) via TrueSpam API. Block, Rename, or Redirect calls based on a score 0-100.
- [Watch Lists and Triggers](https://docs.calltelemetry.com/policies/watch-lists/overview.html) to monitor and send email alerts in your environment for suspciious activity and call volume spikes. You can comment on, Block, or Ignore Watch List numbers.
- [Call Blocking API](https://docs.calltelemetry.com/mcid/block-list-api) for bulk call block management.
- Self Care Portal for Users
  - Users can manage their own call history and block list.
  - [Jabber Portal](https://docs.calltelemetry.com/mcid/jabber) for Cisco Jabber users to see history and block calls.
  - [Phone XML Portal](https://docs.calltelemetry.com/mcid/phone-xml-service) for Cisco IP Phone users to see history and block calls.
  - One click [MCID softkey](https://docs.calltelemetry.com/mcid/user_mcids) to block calls.

Learn more about [Call Blocking](https://docs.calltelemetry.com/mcid/intro) tools available in Call Telemetry.

### [Greeting Injection](https://docs.calltelemetry.com/policies/rule_greetings)

- [Greeting Injection](https://docs.calltelemetry.com/policies/rule_greetings) using native Cisco Callmanager Announcement Media Resources.
- Injecting Announcements does not require Unity Connections, UCCX, UCCE, or CVP.
- Greeting Injection does not change your intended callflow.

#### [Call Apps and Event Webhooks](https://docs.calltelemetry.com/policies/call-apps)

- TrueSpam API for realtime caller spam robocall score, with actions to block call, redirect, or rename.
- [CSV Lookup to locate subnets](https://docs.calltelemetry.com/policies/apps/e911-subnet-csv) for location data - Locate phones in MRA, VPN, or Site lists.
- ICMP Traceroute to locate the last hop for location data
- Send data via Email or SMS to any destination
- XML SOAP web lookup App for querying APIs
- Share realtime data via webhook to any third party API.
- Need another App? [Contact Us](mailto:jason@calltelemtry.com) to build a custom app for your needs.

#### Build your own CRM Connectors

- Change Calling and Called Names, creating a simple CRM connection for Cisco Callmanager.
- Lookup and modify Caller ID via [Webhook CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-webhook) or [PostgreSQL CRM App](https://docs.calltelemetry.com/policies/apps/crm-integration-postgresql)

## [Phone Dashboard and Remote Control](https://docs.calltelemetry.com/realtime/phone-dashboard-reports)

- Reports showing all details, serial, and CDP and LLDP Switch Neighbor and port for every phone.
- Report on the Firmware Version of all phones
- **International Support** Supports ALL Cisco Callmanager Locales and Phone Languages, not just English.
- Report on the Hardware Version V03 / V04 etc, if you are preparing for a Webex Calling Migration
- Search across any phone field
- Export all or selected phone data
- Remote Control with Live Streaming Screen View of any phone
- Remote Factory Reset Cisco IP Phones

## [CDR Reports](https://docs.calltelemetry.com/cdr/reporting)

- Free SFTP server for CDR processing
- Decodes all Cisco CDR fields, not just epoch timestamps.
- Simple and Advanced reports for quick troubleshooting.
- Low Duration Call Report CDR Anlaytics to find spam robocallers

## [911 Alerts and Emergency Features](https://docs.calltelemetry.com/e911)

- Realtime 911 Alerts with location data for Cisco IP Phones.
- Discover Cisco IP Phone details in realtime.
- Alerts can include CDP neighbor, Subnet, and Cisco Callmanager data.
- Notications for Email, SMS, MS Teams, and Webex Teams.
- Creates a Webex Teams Space for each rule alert, invites others, and allows you to collaborate as a team in the space for situational awareness of the call.

### [Dispatchable Location Discovery Apps for Emergency Alerts](https://docs.calltelemetry.com/e911)

- [Discovery](https://docs.calltelemetry.com/policies/apps/e911-phone-discovery) of CDP and LLDP Netowrk Switch Neighbor, IP Subnet, and ICMP traceroute for use in call workflows.
- 911 Location Manager covering Neighbor CDP LLDP Switch, Port, and [Subnet locations](https://docs.calltelemetry.com/policies/apps/e911-subnet-csv).
- Query APIs for dispatchable emeregency location data from discovered Cisco IP Phone data.
- Meraki Location Sync for CDP neighbors and pulls switch physical address and notes.
- 911 [QR Code generator](https://docs.calltelemetry.com/e911/qr-code) for network drop wire mapping.

## [Missed Call Alerts and Notifications](https://docs.calltelemetry.com/missed-call/intro)

- Missed call alerts to Email or Webex App
- Auto synchronization and provision of all Cisco Callmanager users nightly
- Add prefix to calling party to normalize outbound callback
- Lookup name and match Caller ID to internal callers
- Bulk import of users if you don't want to sync.
[Learn more about Missed Calls](https://docs.calltelemetry.com/missed-call/intro)

## [CDR Webhooks](https://docs.calltelemetry.com/cdr/webhooks)

Fire off a webhook for every call event in CDR matching multiple conditions. Include CDR data in the webhook payload.
