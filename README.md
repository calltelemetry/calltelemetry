# Support Repo for CallTelemetry


## On-Prem Instructions
The code is inside a private repo, please use this repo for issue tracking purposes.

### Install Docker and Docker Compose for your OS
https://docs.docker.com/v17.09/engine/installation/

https://docs.docker.com/compose/install/

### First - Launch the Web App (Elixir) and the Database (Postgres)
``` bash
docker-compose up -d

```

### Run Initial Migrations and OnPrem Admin.
You should migrate anytime you upgrade versions - the database structure may have changed.
The onprem_admin seed creates admin@example.com with a password of admin. You can change it in the web app.

``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Release.migrate

docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Seeds.onprem_admin
```
Once completed, you can login to CallTelemetry at http://yourIP:4000

Username: admin@example.com

Password: admin

# FAQ
### Licensing On-Prem
The build - calltelemetry/web:version-0.2.6 is unlimited in usage but this Beta release is set to expire Feb 1, 2020. There will be a new release to extend the trial or license the server before that time.
