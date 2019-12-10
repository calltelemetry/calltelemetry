# Simple and Scalable Incoming Call Blocking for Cisco Callmanager 
A docker-compose solution with SFTP, PostreSQL, Elixir, a SIP Server, and a Cisco CDR Parser - to create a scalable call platform for incoming call blocking and (later) other actions and triggers.

Latest version 0.3.2
Features:
* CURRI / External Call Control Policy Routing API server which can apply to any Phone, Route Pattern, or Translation Pattern, even across over multiple CUCM Clusters.
* WebUI to enter blocked calls manually and view events.
* CDR Parsing of Malicious Caller ID calls to block list - users just press the MCID softkey to add a call to the block list.
* SIP Transfer for users to transfer bad calls into, which adds to the block list.
* Full CDR decoding of every field per Cisco CDR API.
* More features coming!

Visit www.calltelemetry.com/getting_started for the latest instructions
