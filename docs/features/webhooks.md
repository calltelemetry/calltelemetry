# Webhooks
Webhooks allow you to take realtime call data, and pass it to any API. You can add multiple headers as needed. The payload is tested with JSON endpoints.

### Create a WebHook on the main page.
WebHooks can be associated to any Rule within a Policy. You can use variable names like {{event.calling_name}} and others listed on the page to enrich your API request.
![webhook](webhook-detail.png)

### Associate to Rule
Then from a rule you would associate it as an action
![webhook-rule](webhook-rule.png)

