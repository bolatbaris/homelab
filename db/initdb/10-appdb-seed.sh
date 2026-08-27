#!/bin/sh
# Seed the application role and databases.
#
# The PostgreSQL entrypoint runs everything in /docker-entrypoint-initdb.d
# exactly once: when the data directory is empty. That contract is what makes a
# restore win over the seed -- restore.sh repopulates ./data/appdb/postgres, so
# the directory is no longer empty and this never runs. On a genuinely fresh
# machine it means no manual CREATE DATABASE.
#
# Values come from .env via docker-compose.yml. Changing them later does NOT
# change an existing cluster; see deployment.md section 14 for rotation.
set -eu

log() { printf '[appdb-seed] %s\n' "$*"; }

APP_USER="${APPDB_APP_USER:-}"
APP_PASSWORD="${APPDB_APP_PASSWORD:-}"
APP_DATABASES="${APPDB_DATABASES:-}"

[ -n "$APP_USER" ] || { log "APPDB_APP_USER is empty. Refusing to seed."; exit 1; }
[ -n "$APP_PASSWORD" ] || { log "APPDB_APP_PASSWORD is empty. Refusing to seed."; exit 1; }

# Role and database names become SQL identifiers. Identifiers cannot be
# parameterized the way values can, so reject anything unusual rather than
# attempt to quote it. Passwords are values and go through psql's :'var'
# quoting below, so they may contain anything.
valid_ident() {
  printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'
}

valid_ident "$APP_USER" || {
  log "APPDB_APP_USER='$APP_USER' is not a valid identifier (^[a-z_][a-z0-9_]{0,62}\$)."
  exit 1
}

log "Creating role $APP_USER"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v role="$APP_USER" -v pw="$APP_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec
SQL

for db in $(printf '%s' "$APP_DATABASES" | tr ',' ' '); do
  [ -n "$db" ] || continue
  valid_ident "$db" || {
    log "APPDB_DATABASES entry '$db' is not a valid identifier (^[a-z_][a-z0-9_]{0,62}\$)."
    exit 1
  }

  log "Creating database $db owned by $APP_USER"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
       -v db="$db" -v role="$APP_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec
SQL

  # This server hosts several applications. Default PUBLIC CONNECT would let
  # any future role read any other application's database.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
       -v db="$db" -v role="$APP_USER" <<'SQL'
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'db')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'role')
\gexec
SQL
done

log "Seed complete."
