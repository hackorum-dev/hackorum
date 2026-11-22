#!/usr/bin/env bash
set -euo pipefail

UMAMI_DB="${UMAMI_DB:-umami}"
UMAMI_DB_USER="${UMAMI_DB_USER:-umami}"
UMAMI_DB_PASSWORD="${UMAMI_DB_PASSWORD:-umami}"

# psql vars are not expanded inside DO $$ bodies, so \gexec instead
psql -v ON_ERROR_STOP=1 \
  -v UMAMI_DB="$UMAMI_DB" \
  -v UMAMI_DB_USER="$UMAMI_DB_USER" \
  -v UMAMI_DB_PASSWORD="$UMAMI_DB_PASSWORD" \
  --username "$POSTGRES_USER" \
  --dbname "postgres" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'UMAMI_DB_USER', :'UMAMI_DB_PASSWORD')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'UMAMI_DB_USER')\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'UMAMI_DB', :'UMAMI_DB_USER')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'UMAMI_DB')\gexec
EOSQL
