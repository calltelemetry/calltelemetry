# Cisco APIs used
CallTelemetry uses realtime feeds to create actionable events from Cisco Callmanager / Communications Manager.

* Cisco CURRI API provides realtime call event data, and policy control from Cisco CUCM.
* Cisco XCC API on IOS provides realtime call even data, and policy control  from CUBES.
* Cisco CDR is processed to obtain additional telemetry, including MCID flags.

Both of these integrations are "push" integrations to CallTelemetry. No CUCM credentials are required for any integrations, thereby minimizing your security exposure.
# High Level Diagram

![curri](architecture.png){:height="75%" width="75%"}