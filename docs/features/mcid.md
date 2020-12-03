# MCID Blocking
## Background
MCID - Malicious Caller ID Tag - was released in Callmanager 4.0.1, in 2004. It's a softkey on the phone built into Callmanager. When the user is on a call, they can press "MCID", this will flag the call in CDR records. CallTelemetry Server will process CDR and look for the flag, and add it to the Call Policy API.

## Scope of MCID Blocking
MCIDs are enforced globaly for the Organization. Additionally, each policy has an option to allow blocking of MCID protection or not.

## User Submissions of MCIDs
!!! success "Users can only block their own lines. MCID submissions only apply to the phone that submitted them."
User Submissions are Calling + Called number, and applied for that exact combination. This means - your users cannot submit wide impacting rules - only the rules that apply to their phone.

## Expirations

!!! note "MCIDs do not expire by default, but can be set under Organization Settings."
!!! note "Admin MCID blocks never expire."
You can set the expiration of MCIDs to allow for them to be purged over time.
![mcid](org_settings.png)

## Deleting MCIDs
MCIDs are listed under MCID Submissions, and you can delete any entry, and see it's expiration schedule if set.
0 days means never expire.
![mcid](mcid_table.png)

