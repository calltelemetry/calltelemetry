## You can easily load test your own installation.
Get the curri test request file
```
wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/docs/testing/curri.xml
```

Install Ali Testing per your OS (here)[https://github.com/nakabonne/ali]

Now get your CallTelemetry policy URL from the Web Portal, replace it here, and change --rps to increase the numer of requests per second. Hit Enter to run the test.
```
ali -w=1 -r 100 -d=0 http://192.168.123.135/curri/policy\?api_key\=089131c3-6de2-4cc2-ae97-cd20975cd09e --method=POST --body-file curri.xml
```
