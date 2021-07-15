# Cisco APIs used
CallTelemetry uses realtime feeds to create actionable events from Cisco Callmanager / Communications Manager.

* Cisco CURRI API provides realtime call event data, and policy control from Cisco CUCM.
* Cisco XCC API on IOS provides realtime call even data, and policy control  from CUBES.
* Cisco CDR is processed to obtain additional telemetry events, including MCID flags, and missed calls.

Security Notes:
* CURRI, CUBE, and CDR do not require any CUCM, or IOS credentials to work.
* AXL Synchorization requires read-only AXL access to the CUCM API to read User data from CUCM. It's an optional feature, used with Missed Call Alerts.
# High Level Diagram

![curri](architecture.png){:height="75%" width="75%"}