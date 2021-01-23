## You can easily load test your own installation.

```
cat <<EOF > curri.xml
<!--?xml version="1.0" encoding="UTF-8"?-->
<Request xmlns="urn:oasis:names:tc:xacml:2.0:context:schema:os">
    <Subject SubjectCategory="urn:oasis:names:tc:xacml:1.0:Subject-Category:access-Subject">
        <Attribute AttributeId="urn:oasis:names:tc:xacml:1.0:Subject:role-Id" datatype="http://www.w3.org/2001/XMLSchema#string"> Issuer="Requestor">
            <AttributeValue>CISCO:UC:UCMPolicy</AttributeValue>
        </Attribute>
        <Attribute AttributeId="urn:Cisco:uc:1.0:callingnumber" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>123</AttributeValue>
        </Attribute>
        <Attribute AttributeId="urn:Cisco:uc:1.0:callednumber" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>456</AttributeValue>
        </Attribute>
        <Attribute AttributeId="urn:Cisco:uc:1.0:transformedcgpn" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>123</AttributeValue>
        </Attribute>
        <Attribute AttributeId="urn:Cisco:uc:1.0:transformedcdpn" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>456</AttributeValue>
        </Attribute>
        <Attribute AttributeId="urn:Cisco:uc:1.0:callingdevicename" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>SEP1231231234</AttributeValue>
        </Attribute>
    </Subject>
    <Resource>
        <Attribute AttributeId="urn:oasis:names:tc:xacml:1.0:Resource:Resource-Id" datatype="http://www.w3.org/2001/XMLSchema#anyURI">
            <AttributeValue>CISCO:UC:VoiceOrVIdeoCall</AttributeValue>
        </Attribute>
    </Resource>
    <action>
        <Attribute AttributeId="urn:oasis:names:tc:xacml:1.0:action:action-Id" datatype="http://www.w3.org/2001/XMLSchema#anyURI">
            <AttributeValue>any</AttributeValue>
        </Attribute>
    </action>
    <Environment>
        <Attribute AttributeId="urn:Cisco:uc:1.0:triggerpointtype" datatype="http://www.w3.org/2001/XMLSchema#string">
            <AttributeValue>translationpattern</AttributeValue>
        </Attribute>
    </Environment>
</Request>
EOF

rpm -ivh https://github.com/nakabonne/ali/releases/download/v0.5.4/ali_0.5.4_linux_amd64.rpm
```

Now get your CallTelemetry policy URL from the Web Portal, replace it here, and change --rps to increase the numer of requests per second. Hit Enter to run the test.
Read more about Ali Testing (here)[https://github.com/nakabonne/ali]
```
ali -w=1 -r 100 -d=0 http://192.168.123.135/curri/policy\?api_key\=089131c3-6de2-4cc2-ae97-cd20975cd09e --method=POST --body-file curri.xml
```
