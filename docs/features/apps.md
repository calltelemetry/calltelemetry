# Apps
[Latest App Catalog](https://www.calltelemetry.com/features/apps)  
Apps are a modular service that can trigger on any rule event. 

## What can apps do?
### Alerts
You can "alert" via any integration - Webex Teams, Email, or whatever comes next.
### Modifying call data
Some apps will store state, and "remember" calls. They will modify calls if necessary.  For example, if you had a web service that queried an API, you could modify a call in realtime by providing a matching response. More on this later.
### Modifying call flow
Some apps will perform native actions - like redirecting a call. For example, to authenticate the caller, the service might redirect the call to an IVR to enter a code, then on the second time hitting the App let the caller through the system.

# App List
## Send a Message via Webex Teams
Posts a message into a Webex Teams Space.
## Send a Message via Twilio SMS
Sends a message to a list of SMS numbers.
## Send a Message via SMTP
Sends a message to a list of email addresses via SMTP