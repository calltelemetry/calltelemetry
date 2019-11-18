# On Premise version of Call Telemetry

### First - Launch the Web App (Elixir) and the Database (Postgres)
``` bash
docker-compose up -d
```

### Second - Run the DB Migration Scripts
``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Release.migrate
```

### Last - Run the initial Admin user creation.
Username admin@example.com

Password admin

``` bash
docker-compose run web ./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Seeds.onprem_admin
```
