## Rule Matches:
A blank field will match all.
There is no RegEx or *, but let me know if you want that feature.

## Rule Actions:
### 1. Block or Permit
You can block or permit the call. If you block, the Caller will hear a fast busy tone, as the call is rejected.
![rule_match](rule-match.png)

### 2. Inject Greeting
You can inject a callmanager greeting to any call. Upload audio to Callmanager as an Announcement, and match the exact name to the field in the CallTelemetry Rule.
![greeting](greeting_screenshot.png)

### 3. Modifiers
You can dynamically change 4 things about the call - the calling and called number, and the calling and called name.
![modifiers](modifiers.png)

### 4. Email Alerts
You can enter emails to alert multiple email addresses of a call event. There is a default template with some variables pre-populated.
At this time, you cannot modify the template, but let me know if you want to edit it, I'll code that when asked for it.
![email](email.png)

### 5. Webhooks
You can associate WebHooks to a rule to trigger real-time call data to POST to those API servers. You can customize the template sent in the WebHook setup, but not within the rule.
Pressing + will associate the WebHook to the rule, and Pressing - will remove it from the rule.
![webhook-rule](webhook-rule.png)