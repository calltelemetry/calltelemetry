# Troubleshooting CDR

1. Restart the Csico CDR Agent in Cisco CUCM Servicability - Tools -> Control Center Network Services. I've found in lab testing, that it often gets stuck on CDR Server changes.
2. Check the logs. On Docker you can SSH to the box with centos/centos.
```
cd calltelemetry
docker-compose logs
```

A successful CDR Upload will look like this.
```
[info] SFTP: Authenticating User
[info] SFTP: Authenticating User/Pass
[info] SFTP: File uploaded by 7REI4Y //7REI4Y/cdr_StandAloneCluster_01_202012021653_823
[info] CDR: Found CDR Integration for CDR user 7REI4Y
[info] CDR: Parsing CDR for user 7REI4Y
[info] CDR: Parsing file.
[info] CDR: Looking for MCID
[info] CDR: Inserting call. Org Name: Your Org
[info] CDR: Updating Last Seen 
[info] CDR Integration - Last Seen Changeset
[info] CDR: Deleting file /7REI4Y/cdr_StandAloneCluster_01_202012021630_817
```

If you get logs otherwise, send them to me in Webex Teams Space.