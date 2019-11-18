# On Premise version of CallTelemetry CURRI Blocking

### Install Docker and Docker Compose for your OS
https://docs.docker.com/v17.09/engine/installation/

https://docs.docker.com/compose/install/

### First - Launch the Web App (Elixir) and the Database (Postgres)
``` bash
docker-compose up -d
```

### Second - Run the DB Migration Scripts
``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Release.migrate
```

### Last - Run the initial Admin user creation.

``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Seeds.onprem_admin
```
Once completed, you can login to CallTelemetry at http://yourIP:4000

Username: admin@example.com

Password: admin
