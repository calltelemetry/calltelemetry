# Onborading Guide - External Call Control / CURRI 
# 1. In Callmanager, Create an ECC Profile
![ecc-menu](ecc-menu.png){: style="height:400px;width:250px"}

# 2. Point ECC Profile to Calltelemetry
![ecc-add](ecc-add.png){: style="height:300px;width:500px"}

Copy the URL from your Policies Page by clicking here. Docker will not expose the IP of the host, so in most cases you will get "localhost" as the hostname - replace that with the IP of the box.
![policy-copy](policy-copy.png){: style="height:100px;width:150px"}

#### Make sure to include port 80 as shown.
Fill in the ECC Settings
```
Name: Policy Name
Primary Web Service: http://calltelemetryhost:80/api/etc 
Enable Load Balancing: No
Call Treatment on Failures: Allow
```
# 3. Verify it shows as registered in CallTelemetry
Anytime you have an ECC Profile built in Callmanager, Callmanager will reach out and try to register to the policy server.
If your policy is not Registered, your rules won't work either.
![policy-health](policy-health.png){: style="height:125x;width:150px"}


# 4. Assign to Phones or Patterns
You can apply ECC profiles to a Phone, Translation or Route Pattern.
You can use Bulk Tools like BAT for large applications. 

## Example for a phone
![ecc-add](ecc-phone.png){: style="height:300px;width:500px"}

## Example for a Pattern
![ecc-add](ecc-translation.png){: style="height:300px;width:500px"}