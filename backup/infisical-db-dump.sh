#!/bin/sh
set -u

DUMP_DIR="${DUMP_DIR:-/dumps}"
DUMP_KEEP_DAYS="${INFISICAL_DB_DUMP_KEEP_DAYS:-14}"
DUMP_HOUR="${INFISICAL_DB_DUMP_HOUR:-2}"
DUMP_MINUTE="${INFISICAL_DB_DUMP_MINUTE:-30}"
PGHOST="${PGHOST:-infisical-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-infisical}"
PGDATABASE="${PGDATABASE:-infisical}"

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
    log "INFISICAL_DB_DUMP_HOUR, INFISICAL_DB_DUMP_MINUTE, and INFISICAL_DB_DUMP_KEEP_DAYS must be unsigned integers."
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

dump_once() {
  mkdir -p "$DUMP_DIR"
  ts="$(date '+%Y%m%d-%H%M%S')"
  tmp="$DUMP_DIR/infisical-$ts.dump.tmp"
  final="$DUMP_DIR/infisical-$ts.dump"
  latest_tmp="$DUMP_DIR/infisical-latest.dump.tmp"
  latest="$DUMP_DIR/infisical-latest.dump"

  log "Checking Infisical PostgreSQL readiness at $PGHOST:$PGPORT."
  if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"; then
    log "Infisical PostgreSQL is not ready; dump skipped."
    return 1
  fi

  log "Creating Infisical logical dump $final."
  if ! pg_dump --format=custom --no-owner --no-privileges --file "$tmp" "$PGDATABASE"; then
    rm -f "$tmp"
    log "Infisical logical dump failed."
    return 1
  fi

  mv "$tmp" "$final"
  cp "$final" "$latest_tmp"
  mv "$latest_tmp" "$latest"
  find "$DUMP_DIR" -type f -name 'infisical-*.dump' ! -name 'infisical-latest.dump' -mtime "+$DUMP_KEEP_DAYS" -delete || true
  log "Infisical logical dump finished."
}

if [ "${1:-}" = "once" ]; then
  validate_config
  dump_once
  exit $?
fi

validate_config

if [ "${INFISICAL_DB_DUMP_ON_START:-true}" = "true" ]; then
  dump_once || true
fi

while :; do
  sleep_for="$(next_sleep_seconds)"
  log "Next Infisical logical dump scheduled in $sleep_for seconds."
  sleep "$sleep_for"
  dump_once || true
done
