# Changelog

## 0.4.4 <small>7-15-2021</small>

- CDR Missed Call Alerts - Toggle per user, emails the user of the missed call.
- Callmanager User Sync - Automatically syncs User data (Name, Email, Extension) with one or more Callmanagers every 15 minutes.
- Org wide defaults for SMTP, Webex, and Twilio, along with Test options on WebexTeams and SMTP.
- New UI Framework - CDR Events, MCID, CDR Call History, Policy History, End Users (AXL Sync), and Settings have a nice new user interface - completely rebuilt!

## 0.4.3 <small>-5-5-2021</small>

- Spam Investgiation Dashboard - Explore short duration calls that your users might not report. Look for trends in recent CDR calls based on duration and frequency to identify spam callers. More to come here.
- Live CDR Logs - you can now view CDR processing in realtime without going to the console logs.
- New Marketing Web Page launched in April.
- Transition from perpetual development builds to license keys.

## 0.4.2 <small>-3-10-2021</small>

- CUBE Integration - CUBEs are now supported through native Cisco XCC APIs. You can add a CUBE, and link each to any policy. The CUBE page provides the 4-5 lines of CLI to link your CUBEs to Call Telemetry.

## 0.4.1 <small>-2/28/2021</small>

- Lots of improvements to the HA Clustering from production deployments.
- RegEx Patterns on Rules - Allowing more complex combinations.
- Compliance Rules - Org Wide Priority Policies, with dynamic Spam Lookup support, before handing the call to the user policies.
- New App: TrueSpam Spam Lookup - First Compliance Spam Lookup App - dynamically query Spam APIs to block smarter.
- Optimization & Caching - 3x Performance! - 100 call inspections per core per second in under 15ms on the OVA. Profiled 700/call inspections/second running the OVA on 8 cores. Need more? See HA Clustering.
- Webex Teams App supports Markdown
- More Data Fields available in Apps
- Enhancements to Live Logging process.
- Policies now reflect the cause of the action taken.
- Pricing Page added
- Minor Bug Fixes
- UI updates:
- Admins Page
- License Page
- Org Drop Down Selection on sidebar
- Password Reset Page
- More detail on Rule Pages - drop down with Apps and Modifiers in the rule.
- 0.4.1 expires 3-31-2021 without a permenant license.

## January Updates <small>-1/2021</small>

- HA Clustering available - Load Balancing and full failover - [here](deployment/k3s.md)
- OVA Builder scripting: OVAs are automatically built fresh from CentOS 8.3 every release.
- Uploaded new Docker-Compose OVA
- Uploaded Cluster starter OVA
- Sizing Guide [here](deployment/sizing.md)
- Load Testing instructions [here](deployment/load-testing.md)

## 0.4.0 <small>-12/2/2020</small>

- New App: Send Message to Calling Number - for Post Call Surveys
- New App: Webhooks (migrated from existing Webhook feature)
- New MCID Page - CDR Status, and MCIDs
- New Bulk Rule Import/Export - Import/Export multiple rules in bulk
- New IOS Rule Import / Export - direct from IOS translation rules
- New CDR Parser: Rebuilt CDR parser for stability.
- New Organization Feature: - Add multiple team members to an Organization to manage policies.
- CDR MCID: Prior to 0.4.0 - CDR MCID were added to the "Default Policy" only. Now they are stored in a Organization MCIDs Table.
- Added ability for policies to block on MCIDs, or ignore them.
- Daily SQL backups on the OVA
- Breaking Changes:
  - WebHooks are now an App.
- Kubernetes manifest is not ready for 0.4.0 yet - coming soon.

## 0.3.9 <small>- 11/5/2020</small>

- New: Apps - Customizable App structure.
- New: App: Native Webex Teams Alert
- New: App: Native SMTP Alert
- New: App: Native SMS Alert
- New: Added Manual CDR Upload to CDR Reports page
- New: Added Parser support for CUCM 12.5 CDR.
- Change: Beta Build Expires 1/31/2021
- Breaking Changes:
  - "Alerts" are now within Apps. This allows full customization of the Alert in any format - Teams, SMS, SMTP, or whatever comes next.
  - Removed Alerts Tab in Rule Edit.
  - Removed SMTP Settings Page - SMTP Settings are now part of Apps.
  - Previously defined SMTP/Email Alerts will still work this release as transition release - but will not show up in the UI. This feature will be officially removed in 0.4.0.

## 0.3.8 <small>- 9/24/2020</small>

- New: _Webhooks / Apps _ - Add multiple HTTP triggers to any realtime call event! Apps are coming and will be even smarter.
- New: OVA Pre-Built Appliance Release
- _UI Updates_ - Many UI enhancements, more to come.
- New: Documentation Site - [here](https://calltelemetry.readthedocs.io/)
- New: _Expire MCID submissions_ - Configure a day limit for user submissions to automatically expire/delete.
- New: Policies UI consolidated - history, search, live logs, all from the Policies View.
- New: Improved Settings Page with Tabs
- Fixed: _SMTP_ - had some issues found in testing.
- Fixed: Hit counters.
- This version is still unlimited and this release expires on 12/31/2020
- Fixed: Standardized time entries to UTC.
- Removed Discord Community Link.
- Added Webex Teams - you can now join a dedicated room in Cisco Webex Teams - see footer.

## 0.3.7 <small>- 8/5/2020</small>

- Added _Live Logging_ - Streaming logs of realtime call processing for CURRI_API. Now you can see calls and policy decisions made - in Realtime.
- Updated _CDR Uploads_ Page - Now you can upload multiple CDR files via drag and drop. CDR will be processed to the Log View, where every field is decoded, and Malicious caller tags are written into your default policy.
- Added _Called Party Translation_ - reroute callers to any new number using Policies.
- Added _Calling Party / Calling Name _ - change the caller ID of any call in realtime.
- Added _Event Bus_ - This is currently more an internal feature, and optimizes realtime responses and lays work for third more exciting integrations.

## 0.3.6 <small>- 7/20/2020</small>

- Updated, tested and Simplified documentation.
- Removed Linux option compiled per Distro. If you need linux only and no docker, let me know.
- Add **Email Alerts** + SMTP Support.
  - You can now receive an Instant Email Alerts on any Route Point, Translation, or Phone Number - including Emergency Alerts like 911 Patterns. CDR not required, and more than one email address can be added.

## 0.3.5 <small>- 3/20/2020</small>

- Add **Greeting Injection** support for Permit and Block Actions.
  - You can now inject greetings without blocking calls - for example to inject a Coronavirus greeting to every call into your cluster.
  - You can use this by typing the exact name of the greeting in Callmanager Announcements into the rule, shown below.
- Add **Permit** action - you can now have policies that do not block.
- Add **default action** - calling and called numbers can be blank to match all calls in a policy.

## 0.3.4 <small>- 3/15/2020</small>

"Call Actions/Triggers" are coming soon, but every feature includes the UI complexity. I focused on this release to be simpler to use, easier to deploy, and better tested.

Web Pages & How-to Videos:

- Video training on deployment and onboarding

Elixir/Phoenix:

- Updates to latest versions, including minor refactoring to comply with library changes.

UI:

- Intense effort to simplify, and build easier to understand User Interface.
- Quick Add of numbers for manual entry

![quick](/images/releasenotes/quick-add.gif) {:height="50%" width="50%"}

- Policy Keepalive - shows multiple Health status for each Policy's Keepalive to Callmanager. It also detects failure, and shows the last time seen.

![health](/images/releasenotes/policy-health.png) {:height="30%" width="30%"}

- Call Logs -
  - View Live CURRI API Calls.
  - Quick Block / Permit Toggle
  - Policy result history tracking

![health](/images/releasenotes/call-logs.gif) {:height="50%" width="50%"}

- Moved version to Navbar, simplified Navbar
- CDR UI cleaned up

Deployment:

- Improved Documentation on Docker Install
- Added Kubernetes Deployment Model

Support:

- Intensely tested every part of the application.
- Removed Slack Channel (invite process is messy)
- Added Discord Channel - easy to join, no invite process.
- Removed Twitter Handle - I'm not using it yet.

## 0.3.3 <small>- 2/27/2020</small>

Enhancements

- Called party rules. Policies can now be Calling, Called, or Both party matches now. Rules have a calling and called field. Policy type determines what is used.
- UX Enhancements
- Time limits removed, no expiration date.

## 0.3.2 <small>- 12/10/2019</small>

New Features

- SIP Service - Point a route pattern at a Callmanager SIP Trunk towards the IP of the CallTelemetry host (on-premise), and you can now transfer calls to add them to the call block list.
- UX Enhancements

Bug Fixes

- Call Pagination issues

## 0.3.1 <small>- 12/4/2019</small>

New Features
Introducing the Industry First CDR to CURRI Integration, allowing automatic incoming call blocking!

- SFTP Server - To accept CDR uploads from Callmanager. Tightly integrated so that the login is exactly the same as the Web Interface of your server.
- CDR Parser - Full support of all CDR(Call Detail Record) fields from Cisco UCM viewable in the web UI. We support 11.x and 12.x. If you have errors send an example of your failed CDR file to me, I can easily add more parsers.
- MCID Automatic Blocking - Detection of Malicious Caller-ID (MCID) flag and automatically blacklisting the caller without any interaction beyond the user pressing the MCID softkey.

## 0.2.9 <small>- 11/1/2019</small>

First Public Release for On-Prem.

0.2.9 expires Feb 1 2020.
New Features

- Cisco Incoming Call Blocking - You can apply a call block policy to any Route Pattern, Translation, or Directory Number. You can spread that to multiple CUCM Clusters to have complete call blocking globally.
- Call Logging - All calls from devices using the policy are available in the CURRI Call log.

## 0.2.0 <small>- 9/1/2019</small>

Cloud only. Proof of concept available for public demo.
