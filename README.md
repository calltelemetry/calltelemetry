# Call Policy and 911 Location Discovery for Cisco Callmanager

---

## Free Community Edition with advanced features in paid editions.

Looking for the OVA download? [Get Started](https://calltelemetry.com/getting-started)
Visit [Call Telemetry](https://calltelemetry.com) for features.
Visit [Docs](https://docs.calltelemetry.com) for installation instructions

Features:

# Realtime Call Policy Engine

## Alerts

- Instant 911 Alerts
- Alerts can include realtime CDP neighbor, subnet, and CUCM fields.
- Email, SMS, Webex Teams Integration
- Creates a Webex Teams Space for each rule alert, invites others, and allows you to collaborate as a team in the space for situational awareness of the call.

## Location Tools

- Real-time discovery of CDP Neighbor, Subnet (as the call is ringing!).
- 911 Location Manager: Subnet, Switch, Port, and Phone level.
- Realtime data is correlated with Location data in Call Telemetry Sever.
- APIs can query any other API you have, to correlate caller location.
- Meraki Location Sync for CDP neighbors and pulls switch physical address and notes.
- 911 QR Code Location Tool for easy location updating

## API Integrations

- Trigger webhooks to push realtime data to third party services.
- Want to share realtime data to your CRM platform - easy.

## Call Policy Engine

- Inbound & Outbound call block rules to block harassing callers or spam.
- Processed MCID triggers so that users press one button to block calls.
- Add "Apps" and Webhooks to any call event.
- Self Service Blocking via Jabber custom tab
- Access Phone details, CDP neighbor data, and Subnet in your alerts/webhooks.
- Use Google Text to Speech to generate announcements and upload automatically across all CUCM Clusters (beta)
- Change Calling / Called Names and Numbers
- Central Policy API across all CUCMs in your environment.

## Integration Apps

- Postgres Lookup of Caller ID
- Webex Teams Space with live call data
- CSV Lookup to locate subnets for location data
- ICMP Traceroute to locate the last hop for location data
- Send data via Email or SMS to any destination
- XML SOAP web lookup
- Share realtime data via webhook to any third party API.

## Greeting Injection

- Greeting Injection on permit or blocked calls.
- Greeting Injection does not require Unity or UCCX.
- Greeting Injection does not change your callflow, even the CDR stays the same.

## Missed Call Alerts
- Missed call alerts to email
- Bulk import of users
# Self Hosted any way you choose

- [Vmware OVA Appliance](https://docs.calltelemetry.com/deployment/ova.html)
- [Docker](https://hub.docker.com/r/calltelemetry/web)
- [Kubernetes](https://docs.calltelemetry.com/deployment/k3s.html)
- [Multinode HA Kubenretes failover](https://docs.calltelemetry.com/deployment/k3s.html)

# 100% Private

- On-premise or your cloud.
- No tracking, analytics, or call home features.

# More Tools

## Remote Control IP Phones

- Remote Control with Live Screen View of any phone

## Phone Inventory Reports

- Reports showing all details, serial, and CDP LLDP Neighbor and port for every phone
- Search across any phone field
- Export all or selected phone data

## Bulk ITL Resets

- Bulk ITL Resets (beta)

## CDR Troubleshooting

- Built in SFTP server for CDR processing
- Decodes all CDR fields
- Simple reports for quick troubleshooting.
- CDR Anlytics to find spam robo callers

---

Visit the official [Release Notes](https://docs.calltelemetry.com/changelog/) full release notes.
- 6-20-2022 0.6.3 - XML SOAP App, Call Simulator page, Bulk import of users
- 6-6-2022 0.6.2 - Inventory and CDR Enhancements
- 6-2-2022 0.6.1 - Small fixes and RIS batching feature
- 5-27-2022 0.6.0 - New app: ICMP Traceroute to CMDB - Lookup last hop for location alert data
- 5-17-2022 0.5.9 - New app: CSV Subnet lookup - lookup subnet for location alert data
- 5-2-2022 0.5.8 - Call Simulator tab on the rule and bug fixes.
- 4-22-2022 0.5.7 - App Data now shared further down the pipeline. New Postgres Caller ID App - you can lookup caller id and replace it in realtime.
- 3-23-2022 0.5.6 - Usability and Logging Enhancements.
- 3-15-2022 0.5.5 - Bug fix with CURRI from security hardening. Port 80 is now only for unsecure api, you cannot pass sensitive credentials on it.
- 3-10-2022 0.5.4 - Add AXL and RIS Lookups into Policy event log. We now do CI/CD vulnerability scanning, and have public vulnerability ratings for our containers on Dockerhub.
- 3-01-2022 0.5.3 - Disabling email activation on registration, all credentials are encrypted, add more SMTP logging details.
- 2-27-2022 0.5.2 - Improved handling of real-time discovery. Enable SSL, disable all analytics and chat, box is air-gapped.
- 2-24-2022 0.5.1 - Minor bug fixes
- 2-16-2022 0.5.0 - Real-time discovery (not sync!) of phones for alerts. Better logging - all alert actions, text, and variables are logged.
- 2-4-2022 - 0.4.9 - Call simulator, Online/offline alerts
- 10-26-2021 - 0.4.8 - Text to Speech announcement work, logging work, and minor bug fixes.
- 9-30-2021 - 0.4.7 - 911 Switch Port Page, Google Text to Speech integration for announcements.
- 9-13-2021 - 0.4.6 - 911 Location Manager, E911 QR Code Survey, Jabber Custom Tabs for blocking, RIS capacity and AXL capacity optimization, CDR upload for multiple files.
- 8-8-2021 - 0.4.5 - Live Phone Data available in Apps, Webhooks, and Alerts. Inventory report with Serials, Subnets, and CDP Neighbors of all phones. Remotely Control of any phone (live streaming Screenshot and keypad), Bulk ITL Reset.
- 7-15-2021 - 0.4.4 - Missed Call Alerts via email, AXL Directory Support, rebuilt many UI screens with better tables and searching.
- 5-5-2021 - 0.4.3 - Spam Investigation Dashboard
- 3-10-2021 - 0.4.2 - CUBE Integration - inbound and outbound policy support
- 2-28-2021 - 0.4.1 - Compliance Rule Type, RegEx patterns, Dynamic Spam Lookups via Twilio.
- 12-02-2020 - 0.4.0 - Send Message to Caller, Bulk Import/Export, IOS Reject Rule Import, Organizations
- 11-07-2020 - 0.3.9 - Customizable Apps, Native Webex Teams, SMS, and Email Apps
- 09-25-2020 - 0.3.8 - WebHooks, OVA Appliance, lots of User Interface work!
- 08-05-2020 - 0.3.7 - Redirect / Calling / Called Party Modifications, Live Logging
- 07-17-2020 - 0.3.6 - Email Alerts added, Kubernetes IP Discovery.
- 03-20-2020 - 0.3.5 - Permit rules added, and CURRI Greeting Injection
- 03-15-2020 - 0.3.4 - UI Enhancement, Kubernetes, Video and Howto Guides.
- 02-27-2020 - 0.3.3 - Called Party Rules
- 12-10-2019 - 0.3.2 - SIP Integration
- 12-04-2019 - 0.3.1 - CDR Integration with MCID added
- 11-01-2019 - 0.2.9 - First Public Self-hosted release using CURRI to block calls
