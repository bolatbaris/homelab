#!/bin/sh
# Scheduled logical PostgreSQL dumps, written beside the service's data so the
# nightly restic snapshot picks them up.
#
# Two modes:
#   DB_DUMP_ALL=false  one pg_dump of $PGDATABASE, named ${DB_DUMP_PREFIX}-<ts>.dump
#   DB_DUMP_ALL=true   pg_dumpall --globals-only, plus one pg_dump per database
#
# The raw data directory is snapshotted by restic too, but it is copied while
# PostgreSQL may be writing to it. These dumps are the trustworthy restore path.
#
# Run a single dump by hand with:  pg-dump.sh once
set -u

DUMP_DIR="${DB_DUMP_DIR:-/dumps}"
DUMP_KEEP_DAYS="${DB_DUMP_KEEP_DAYS:-14}"
DUMP_HOUR="${DB_DUMP_HOUR:-2}"
DUMP_MINUTE="${DB_DUMP_MINUTE:-45}"
DUMP_PREFIX="${DB_DUMP_PREFIX:-database}"
DUMP_ALL="${DB_DUMP_ALL:-false}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"

export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*"
}

to_int() {
  value="$(printf '%s' "$1" | sed 's/^0*//')"
  [ -n "$value" ] || value=0
  printf '%s' "$value"
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_config() {
  if ! is_uint "$DUMP_HOUR" || ! is_uint "$DUMP_MINUTE" || ! is_uint "$DUMP_KEEP_DAYS"; then
    log "DB_DUMP_HOUR, DB_DUMP_MINUTE, and DB_DUMP_KEEP_DAYS must be unsigned integers."
    exit 1
  fi

  hour="$(to_int "$DUMP_HOUR")"
  minute="$(to_int "$DUMP_MINUTE")"
  keep_days="$(to_int "$DUMP_KEEP_DAYS")"

  if [ "$hour" -gt 23 ] || [ "$minute" -gt 59 ] || [ "$keep_days" -lt 1 ]; then
    log "Invalid dump schedule. Use hour 0-23, minute 0-59, and keep days >= 1."
    exit 1
  fi
}

next_sleep_seconds() {
  hour="$(to_int "$(date '+%H')")"
  minute="$(to_int "$(date '+%M')")"
  second="$(to_int "$(date '+%S')")"
  target_hour="$(to_int "$DUMP_HOUR")"
  target_minute="$(to_int "$DUMP_MINUTE")"

  now_seconds=$((hour * 3600 + minute * 60 + second))
  target_seconds=$((target_hour * 3600 + target_minute * 60))
  sleep_seconds=$((target_seconds - now_seconds))
  if [ "$sleep_seconds" -le 0 ]; then
    sleep_seconds=$((sleep_seconds + 86400))
  fi

  printf '%s' "$sleep_seconds"
}

# Publish atomically: write to .tmp, rename into place, then refresh -latest.
# A reader (restic, pg_restore) never sees a half-written dump.
publish() {
  tmp="$1"
  final="$2"
  latest="$3"
  mv "$tmp" "$final"
  cp "$final" "$latest.tmp"
  mv "$latest.tmp" "$latest"
}

dump_database() {
  db="$1"
  prefix="$2"
  tmp="$DUMP_DIR/$prefix-$ts.dump.tmp"

  log "Creating logical dump $DUMP_DIR/$prefix-$ts.dump"
  if ! pg_dump --format=custom --no-owner --no-privileges --dbname "$db" --file "$tmp"; then
    rm -f "$tmp"
    log "Logical dump of $db failed."
    return 1
  fi
  publish "$tmp" "$DUMP_DIR/$prefix-$ts.dump" "$DUMP_DIR/$prefix-latest.dump"
}

# Roles and their passwords live outside any single database. Without them a
# restored database exists but no application can log in to it.
dump_globals() {
  tmp="$DUMP_DIR/globals-$ts.sql.tmp"

  log "Dumping roles and globals to $DUMP_DIR/globals-$ts.sql"
  if ! pg_dumpall --globals-only --file "$tmp"; then
    rm -f "$tmp"
    log "pg_dumpall --globals-only failed."
    return 1
  fi
  publish "$tmp" "$DUMP_DIR/globals-$ts.sql" "$DUMP_DIR/globals-latest.sql"
}

list_databases() {
  psql --dbname postgres --no-align --tuples-only --command \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
}

prune_old_dumps() {
  find "$DUMP_DIR" -type f \( -name '*.dump' -o -name '*.sql' \) \
    ! -name '*-latest.dump' ! -name '*-latest.sql' \
    -mtime "+$DUMP_KEEP_DAYS" -delete || true
}

dump_once() {
  mkdir -p "$DUMP_DIR"
  ts="$(date '+%Y%m%d-%H%M%S')"
  rc=0

  log "Checking PostgreSQL readiness at $PGHOST:$PGPORT."
  if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"; then
    log "PostgreSQL is not ready; dump skipped."
    return 1
  fi

  if [ "$DUMP_ALL" = "true" ]; then
    dump_globals || rc=1
    for db in $(list_databases); do
      dump_database "$db" "$db" || rc=1
    done
  else
    dump_database "$PGDATABASE" "$DUMP_PREFIX" || rc=1
  fi

  prune_old_dumps

  if [ "$rc" -eq 0 ]; then
    log "Logical dump finished."
  else
    log "Logical dump finished with errors."
  fi
  return "$rc"
}

if [ "${1:-}" = "once" ]; then
  validate_config
  dump_once
  exit $?
fi

validate_config

if [ "${DB_DUMP_ON_START:-true}" = "true" ]; then
  dump_once || true
fi

while :; do
  sleep_for="$(next_sleep_seconds)"
  log "Next logical dump scheduled in $sleep_for seconds."
  sleep "$sleep_for"
  dump_once || true
done
