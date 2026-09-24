# Call Telemetry: Call Policy Engine and Realtime Tool Suite for Cisco Callmanager

[Latest Version (0.8.6.27)](https://github.com/calltelemetry/calltelemetry/releases/tag/0.8.6.27) | [Release Notes & Changelog](https://support.calltelemetry.com/changelog)

## Quick Start & Deployment Options

### 1. VMware OVA Appliance (Recommended)
The fastest way to deploy. A pre-built, hardened virtual appliance based on AlmaLinux 9 with all services, storage, and systemd automation pre-configured.

* **[Download Appliance](https://docs.calltelemetry.com/download)** — Request VMware OVA & Nutanix QCOW2 download links
* **[VMware OVA Deployment Guide](https://docs.calltelemetry.com/deployment/ova.html)**

### 2. Bring Your Own OS (Automated Linux Install)
Deploy on an existing Enterprise Linux 9 server (AlmaLinux, Rocky Linux, or RHEL) using the official installation script and `ct` CLI tool:

```bash
# 1. Download and install the Call Telemetry CLI (ct)
curl -fsSL https://get.calltelemetry.com | sudo sh

# 2. Prepare host machine (installs Docker CE, directories, systemd service, SSH port 2222)
sudo ct build-appliance
# (or unattended/headless: sudo ct build-appliance -y)

# 3. Check appliance status or deploy latest stable release
sudo ct status
sudo ct update stable
```

> **Note on SSH Access**: Appliance preparation moves the host SSH daemon to port **2222** (reserving port 22 for Call Telemetry's internal SFTP server for CUCM CDR collection). If reconnecting after `build-appliance`, connect via `ssh -p 2222 user@host`.

* **[Docker Deployment Guide](https://docs.calltelemetry.com/deployment/docker.html)**
* Advanced: A raw [`docker-compose.yml`](docker-compose.yml) and [`.env.example`](.env.example) are provided for custom homelabs.

### 3. High-Availability Kubernetes / K3s Cluster
* **[HA Cluster Deployment Guide](https://docs.calltelemetry.com/deployment/k3s.html)**
* See [`kubernetes/README.md`](kubernetes/README.md) for CloudNativePG and Traefik ingress manifests.

### For AI Coding Agents
Running an automated workflow or working with an AI coding assistant (Claude, Cursor, Copilot, Antigravity, Devin)? See [`AGENTS.md`](AGENTS.md) for narrated architecture boundaries, port mappings, test procedures, and health verification endpoints.

### Private and Secure

- Secure - No internet required. Air gap support.
- Private - No user tracking or analytics.
- RBAC Teams Support - Multi-user Role Based access.
- Encryption Support - TLS Administration, Secure FTP, and Cisco CURRI API TLS support

Free Community License includes these core features:

- Policy Engine with Call Blocking
- Unlimited Permit and Block Rules
- Unlimited Policies
- Greeting Injection
- Global Block List for up to 100 numbers
- Modify Calling and Called Party Numbers and Calling Names
- Phone Dashboard and Neighbor discovery up to 1000 phones
- Phone Remote Control
- Basic CDR and Report data up to 7 days
- CMR Data up to 24 hours
- 1 Administrator
- 1 Callmanager Cluster

Additional features are enabled with a [paid license](https://calltelemetry.com/#pricing).

## Call Policy and CURRI API Engine

[Use Call Policies](https://docs.calltelemetry.com/policies/introduction) to block calls, inject greetings, and add apps to calls.

### Call Policy Features

- [Global Block list](https://docs.calltelemetry.com/call-block/global-call-block-list) blocks calls across multiple clusters.
- Block calls based on calling Party, or a combination of calling and called party.
- Unlimited Call Routing Rules - Block, Permit, Change Caller IDs, Translate / Redirect, or Inject Greetings.
- Multiple Cluster Support - Central Policy control across all Cisco Callmanager clusters in your environment.
- Apps and [Webhooks](https://docs.calltelemetry.com/policies/apps/crm-integration-webhook) to any incoming call event - Send to CRMs, APIs, or build workflows to send complex alerts to teams for Emergency calls.
- Realtime Spam and [Call Reputation scoring](https://docs.calltelemetry.com/policies/truespam_filtering) via TrueSpam API. Block, Rename, or Redirect calls based on a score 0-100.
- [Watch Lists and Triggers](https://docs.calltelemetry.com/policies/watch-lists/overview.html) to monitor and send email alerts in your environment for suspicious activity and call volume spikes. You can comment on, Block, or Ignore Watch List numbers.
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
- Need another App? [Contact me](mailto:jason@calltelemetry.com) to build a custom app for your needs.

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
- Low Duration Call Report CDR Analytics to find spam robocallers

## [911 Alerts and Emergency Features](https://docs.calltelemetry.com/e911)

- [Realtime 911 Alerts](https://docs.calltelemetry.com/policies/trigger-call-alerts) with location data for Cisco IP Phones. Alerts can include CDP neighbor, Subnet, and Cisco Callmanager data.
- Notifications for Email, SMS, MS Teams, and Webex Teams.
- [Discover Cisco IP Phone details](https://docs.calltelemetry.com/policies/apps/e911-phone-discovery) in realtime.
- Creates a Webex Teams Space for each rule alert, invites others, and allows you to collaborate as a team in the space for situational awareness of the call.

### [Dispatchable Location Discovery Apps for Emergency Alerts](https://docs.calltelemetry.com/e911)

- [Phone Discovery](https://docs.calltelemetry.com/policies/apps/e911-phone-discovery) of CDP and LLDP Network Switch Neighbor, IP Subnet, and ICMP traceroute for use in call workflows.
- 911 Location Manager covering Neighbor CDP LLDP Switch, Port, and [Subnet locations](https://docs.calltelemetry.com/policies/apps/e911-subnet-csv).
- Query APIs for dispatchable emergency location data from discovered Cisco IP Phone data.
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

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
