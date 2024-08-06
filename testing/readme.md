# Load Testing CURRI

Install Ali Testing per your OS [here](https://github.com/nakabonne/ali)

Now get your CallTelemetry policy URL from the Web Portal, replace it here, and change -r  to increase the number of requests per second. Hit Enter to run the test.

```bash
ali -w=10 -r 200 -d=0 http://192.168.123.135/curri/policy\?api_key\=089131c3-6de2-4cc2-ae97-cd20975cd09e --method=POST --body-file ./curri.xml
```

More details about CURRI load testing and appliance sizing can be found [here](https://docs.calltelemetry.com/guide/sizing)
