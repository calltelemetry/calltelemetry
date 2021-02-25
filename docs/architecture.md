# Cisco APIs used
CallTelemetry uses realtime feeds to create actionable events from Cisco Callmanager / Communications Manager.

* Cisco CURRI API provides realtime call event data from Cisco CUCM.
* Cisco CDR is processed to obtain additional telemetry, including MCID flags.

Both of these integrations are "push" integrations to CallTelemetry. No CUCM credentials are required for this integration, thereby minimizing your security exposure.
# High Level Diagram

![curri](architecture.png){:height="75%" width="75%"}