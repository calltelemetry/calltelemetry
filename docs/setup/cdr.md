CallTelemetry runs a SFTP Server that accepts Cisco CDR formatted files, processes them, and decodes every field.

This can be used for Rule Matching and alerts, even without attaching the Policy API. Right now, I'm not matching rules on CDR Events.

# Step 1. Enable CDR Processing
1. Go to Callmanager Serviceability - CDR Management. 
2. Add a new CDR Billing Server.
This only needs to be done on the publisher node.
Use the IP of your CallTelemetry server, and the username and password you login to the UI with.

![cdr](cdr-sftp.png)
