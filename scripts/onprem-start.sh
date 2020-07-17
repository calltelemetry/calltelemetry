#!/bin/bash
# Docker entrypoint script.
# Credit https://dev.to/ilsanto/deploy-a-phoenix-app-with-docker-stack-1j9c
# Wait until Postgres is ready
while ! pg_isready -q -h $DB_HOSTNAME -p 5432 -U $DB_USER
do
  echo "$(date) - waiting for database to start"
  sleep 2
done
# createdb -h $DB_HOSTNAME -p 5432 -U $DB_USER calltelemetry_prod
echo "$DB_HOSTNAME:5432:$DB_NAME:$DB_USER:$DB_PASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass
createdb $DB_NAME
./onprem/rel/onprem/bin/onprem eval Cdrcisco.Release.migrate
# ./onprem/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Seeds.onprem_admin
./onprem/rel/onprem/bin/onprem start