#!/bin/sh
# Docker entrypoint script.
# Credit https://dev.to/ilsanto/deploy-a-phoenix-app-with-docker-stack-1j9c
# Wait until Postgres is ready
while ! pg_isready -q -h $DB_HOSTNAME -p 5432 -U $DB_USER
do
  echo "$(date) - waiting for database to start"
  sleep 2
done

./prod/rel/cdrcisco/bin/cdrcisco eval Cdrcisco.Release.migrate
./prod/rel/cdrcisco/bin/cdrcisco start