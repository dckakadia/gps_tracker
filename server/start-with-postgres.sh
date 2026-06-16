#!/usr/bin/env bash
set -euo pipefail

echo "Starting local Postgres container (gps_tracker_db) if not running..."
if [ "$(docker ps -q -f name=gps_tracker_db)" == "" ]; then
  if [ "$(docker ps -aq -f name=gps_tracker_db)" == "" ]; then
    docker run -d --name gps_tracker_db -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgrespw -e POSTGRES_DB=gps_tracker -p 5432:5432 postgres:15
  else
    docker start gps_tracker_db
  fi
else
  echo "Postgres container already running"
fi

echo "Waiting for Postgres to accept connections..."
until docker exec gps_tracker_db pg_isready -U postgres >/dev/null 2>&1; do
  sleep 1
done

echo "Postgres ready. Setting up database schema..."
npm run setup-db

echo "Starting server"
npm run start
