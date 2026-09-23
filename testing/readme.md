# Load Testing CURRI

Install Ali Testing per your OS [here](https://github.com/nakabonne/ali)

Now get your Call Telemetry policy URL from the Web Portal, replace it here, and change -r  to increase the number of requests per second. Hit Enter to run the test.

```bash
ali -w=10 -r 200 -d=0 http://<your-appliance-ip>/curri/policy\?api_key\=<your-api-key> --method=POST --body-file ./curri.xml
```

More details about CURRI load testing and appliance sizing can be found [here](https://docs.calltelemetry.com/guide/sizing)
