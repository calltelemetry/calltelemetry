# Apps
[Latest App Catalog](https://www.calltelemetry.com/features/apps)  
Apps are a modular services that can trigger on any rule event. 

## What can apps do?
### Alerts
You can receive "alert" via Webex Teams, Email, Twilio, and more.

### Modifying call flow
No apps do this today, but in the future, some apps will perform native actions - like blocking or redirecting a call. For example, to authenticate the caller, the service might redirect the call to an IVR to enter a code, then on the second time hitting the App let the caller through the system.

# App List
## Send a Message via Webex Teams Bot
Posts a message into a Webex Teams Space. 
Requires a Bot Token - Obtain your Bot token in the Webex Teams Admin space.
## Send a Message via Twilio SMS
Sends a message to a list of SMS numbers.
Requires Twilio API keys and phone number.
## Send a Message via SMTP
Sends a message to a list of email addresses via SMTP
Requires SMTP credentials for your server.
## Send a Message via Twilio to Caller
Sends a message back to the caller to engage in a new channel. For example - Post Call Surveying, or engaging with Agents via Chat during vs holding.
Requires Twilio API keys and phone number.