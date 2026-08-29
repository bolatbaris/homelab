#!/usr/bin/env bash
# Live-container tests for the appdb seed contract and the shared dump script.
# Not run in CI: it pulls images and starts containers. Run it locally before
# touching db/initdb/ or backup/pg-dump.sh.
#
#   ./tests/appdb-integration.sh
#
# Uses named volumes and `podman cp` rather than host bind mounts. A podman
# machine with no configured mounts -- the macOS default for some VM providers --
# rejects every bind with "statfs ...: connection refused", which would make this
# test unrunnable on the development machine for a reason unrelated to what it
# checks. Named volumes preserve the one property that matters here: PGDATA is
# empty on the first start and populated on the second.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$PWD"

IMAGE="${APPDB_IMAGE:-docker.io/postgres:17-alpine}"
CT="appdb-itest"
DUMPCT="appdb-itest-dump"
NET="appdb-itest-net"
DATA_VOL="appdb-itest-data"
DUMP_VOL="appdb-itest-dumps"
MM_DUMP_VOL="appdb-itest-mm-dumps"
SUPERPW="itest-superuser-pw"
APPPW="itest-app-pw"

FAILURES=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

cleanup() {
  podman rm -f "$CT" "$DUMPCT" >/dev/null 2>&1 || true
  podman volume rm -f "$DATA_VOL" "$DUMP_VOL" "$MM_DUMP_VOL" >/dev/null 2>&1 || true
  podman network rm -f "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

podman network create --internal "$NET" >/dev/null 2>&1 || true
podman volume create "$DATA_VOL" >/dev/null
podman volume create "$DUMP_VOL" >/dev/null
podman volume create "$MM_DUMP_VOL" >/dev/null

# create -> cp the seed scripts in -> start, because the entrypoint reads
# /docker-entrypoint-initdb.d at startup and there is no bind mount available.
start_appdb() {
  podman rm -f "$CT" >/dev/null 2>&1 || true
  podman create --name "$CT" --network "$NET" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD="$SUPERPW" \
    -e POSTGRES_DB=postgres \
    -e APPDB_APP_USER=appuser \
    -e APPDB_APP_PASSWORD="$APPPW" \
    -e APPDB_DATABASES=alpha,beta \
    -v "$DATA_VOL:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  if [ -d "$REPO_DIR/db/initdb" ]; then
    for f in "$REPO_DIR"/db/initdb/*; do
      [ -e "$f" ] || continue
      podman cp "$f" "$CT:/docker-entrypoint-initdb.d/$(basename "$f")"
    done
  fi
  podman start "$CT" >/dev/null
}

wait_ready() {
  for _ in $(seq 1 60); do
    if podman exec "$CT" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

q() { podman exec -e PGPASSWORD="$SUPERPW" "$CT" \
        psql -U postgres -d postgres -Atc "$1" 2>/dev/null; }

# Run pg-dump.sh once against the test database, with the dump directory on a
# named volume. Args: <volume> <extra env>...
run_dump() {
  vol="$1"; shift
  podman rm -f "$DUMPCT" >/dev/null 2>&1 || true
  podman create --name "$DUMPCT" --network "$NET" \
    -e PGHOST="$CT" -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD="$SUPERPW" \
    -e DB_DUMP_KEEP_DAYS=14 \
    "$@" \
    -v "$vol:/dumps" \
    "$IMAGE" /bin/sh /usr/local/bin/pg-dump.sh once >/dev/null
  podman cp "$REPO_DIR/backup/pg-dump.sh" "$DUMPCT:/usr/local/bin/pg-dump.sh"
  podman start -a "$DUMPCT" >/dev/null 2>&1
  podman rm -f "$DUMPCT" >/dev/null 2>&1 || true
}

vol_ls() {
  podman run --rm -v "$1:/dumps" "$IMAGE" ls /dumps 2>/dev/null
}

vol_grep() {
  podman run --rm -v "$1:/dumps" "$IMAGE" grep -q "$2" "/dumps/$3" 2>/dev/null
}

echo "# --- seed on a fresh cluster ---"
start_appdb
wait_ready || { fail "appdb never became ready on a fresh cluster"; exit 1; }

[ "$(q "SELECT 1 FROM pg_roles WHERE rolname='appuser'")" = "1" ] \
  && pass "role appuser created" || fail "role appuser missing"

for db in alpha beta; do
  [ "$(q "SELECT 1 FROM pg_database WHERE datname='$db'")" = "1" ] \
    && pass "database $db created" || fail "database $db missing"
  [ "$(q "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$db'")" = "appuser" ] \
    && pass "database $db owned by appuser" || fail "database $db not owned by appuser"
done

if podman exec -e PGPASSWORD="$APPPW" "$CT" \
     psql -U appuser -d alpha -Atc 'SELECT 1' >/dev/null 2>&1; then
  pass "appuser can log in to alpha with the seeded password"
else
  fail "appuser cannot log in to alpha"
fi

echo "# --- seed must NOT re-run on a populated cluster ---"
q "CREATE TABLE public.itest_marker (id int)" >/dev/null
q "DROP DATABASE beta" >/dev/null
start_appdb
wait_ready || { fail "appdb never became ready on restart"; exit 1; }

[ "$(q "SELECT 1 FROM pg_database WHERE datname='beta'")" = "" ] \
  && pass "seed did not re-create the dropped database" \
  || fail "seed re-ran on a populated cluster and re-created beta"

[ "$(q "SELECT 1 FROM pg_tables WHERE tablename='itest_marker'")" = "1" ] \
  && pass "existing data survived the restart" || fail "existing data lost"

echo "# --- dump: DB_DUMP_ALL=true writes globals plus one file per database ---"
q "CREATE DATABASE beta" >/dev/null
run_dump "$DUMP_VOL" -e PGDATABASE=postgres -e DB_DUMP_ALL=true
dumps="$(vol_ls "$DUMP_VOL")"

printf '%s\n' "$dumps" | grep -qx 'globals-latest.sql' \
  && pass "globals-latest.sql written" || fail "globals-latest.sql missing"
for db in alpha beta postgres; do
  printf '%s\n' "$dumps" | grep -qx "$db-latest.dump" \
    && pass "$db-latest.dump written" || fail "$db-latest.dump missing"
done
printf '%s\n' "$dumps" | grep -q '\.tmp$' \
  && fail "temp files left behind" || pass "no temp files left behind"

if vol_grep "$DUMP_VOL" 'CREATE ROLE appuser' globals-latest.sql; then
  pass "globals dump carries the application role"
else
  fail "globals dump does not contain the application role"
fi

echo "# --- dump: DB_DUMP_ALL=false reproduces the Mattermost filenames ---"
run_dump "$MM_DUMP_VOL" -e PGDATABASE=alpha -e DB_DUMP_ALL=false -e DB_DUMP_PREFIX=mattermost
mmdumps="$(vol_ls "$MM_DUMP_VOL")"

printf '%s\n' "$mmdumps" | grep -qx 'mattermost-latest.dump' \
  && pass "mattermost-latest.dump written (single-database mode unchanged)" \
  || fail "mattermost-latest.dump missing"
printf '%s\n' "$mmdumps" | grep -qE '^mattermost-[0-9]{8}-[0-9]{6}\.dump$' \
  && pass "timestamped mattermost dump written" \
  || fail "timestamped mattermost dump missing"
printf '%s\n' "$mmdumps" | grep -q '^globals-' \
  && fail "single-database mode wrote globals (it must not)" \
  || pass "single-database mode wrote no globals"

echo "# --- a bad identifier must be rejected, not quoted-and-hoped ---"
# The seed builds SQL identifiers, which cannot be parameterized. If validation
# ever regresses, this name is what an injection attempt looks like.
BADCT="appdb-itest-bad"
BADVOL="appdb-itest-bad-data"
podman rm -f "$BADCT" >/dev/null 2>&1 || true
podman volume rm -f "$BADVOL" >/dev/null 2>&1 || true
podman volume create "$BADVOL" >/dev/null
podman create --name "$BADCT" --network "$NET" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD="$SUPERPW" -e POSTGRES_DB=postgres \
  -e APPDB_APP_USER=appuser -e APPDB_APP_PASSWORD="$APPPW" \
  -e 'APPDB_DATABASES=ok_db,evil"; DROP DATABASE ok_db; --' \
  -v "$BADVOL:/var/lib/postgresql/data" "$IMAGE" >/dev/null
podman cp "$REPO_DIR/db/initdb/10-appdb-seed.sh" "$BADCT:/docker-entrypoint-initdb.d/10-appdb-seed.sh"
podman start "$BADCT" >/dev/null 2>&1
sleep 12
badlog="$(podman logs "$BADCT" 2>&1)"
if printf '%s' "$badlog" | grep -q 'is not a valid identifier'; then
  pass "invalid database name rejected by name validation"
else
  fail "invalid database name was not rejected"
fi
if podman exec "$BADCT" pg_isready -U postgres >/dev/null 2>&1; then
  fail "cluster came up despite an invalid APPDB_DATABASES entry"
else
  pass "seed failure stopped the cluster instead of starting half-configured"
fi
podman rm -f "$BADCT" >/dev/null 2>&1 || true
podman volume rm -f "$BADVOL" >/dev/null 2>&1 || true

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
echo "All appdb integration checks passed."
