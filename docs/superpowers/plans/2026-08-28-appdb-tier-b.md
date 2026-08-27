# Application Database (Tier B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a general-purpose PostgreSQL server plus Adminer and a logical-dump sidecar to LocalCloud Stack as the first Private (Tier B) service — reachable only over Tailscale, never through Cloudflare Tunnel or the LAN, seeded from `.env` on a fresh cluster, and covered by the existing restic backup.

**Architecture:** Three new services (`appdb`, `appdb-adminer`, `appdb-dump`) behind a new opt-in compose profile `db`, on a new `internal: true` bridge `appdb-net` that is deliberately not connected to `edge-net`. Exposure is guarded by three independent fail-closed layers: a compose required-variable on the port mapping, an installer precondition, and CI assertions. The existing Mattermost dump script is generalized so both databases share one scheduler.

**Tech Stack:** Podman (rootless) + podman-compose, PostgreSQL 17-alpine, Adminer, restic, POSIX `sh` for container scripts, `bash` for host scripts, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-28-appdb-tier-b-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Never gate startup on health.** No `condition: service_healthy` anywhere. Podman implements healthchecks as systemd user timers; when the timer cannot be created the state stays `starting` forever. Plain `depends_on` only. Healthchecks may exist for `podman ps` visibility.
- **Persistent data only under `./data/<service>/`.** Backup and restore assume this shape.
- **`restart: unless-stopped`** on every long-running service.
- **Optional services behind a profile.** `db` is off by default.
- **Image refs overridable from `.env`.** `APPDB_IMAGE`, `ADMINER_IMAGE`.
- **No bare `"<port>:<port>"` publishes.** Every published port names an interface.
- **Allowed host parts for published ports:** `127.0.0.1`, `${LAN_IP…}`, `${TAILSCALE_IP…}`. Nothing else.
- **Fail closed.** Prefer an explicit error over a guess.
- **podman-compose floor:** `>= 1.1.0` for `--profile` (already enforced). Required-variable `${VAR:?msg}` support is verified at runtime by probe, never by version string.
- **Postgres image:** `docker.io/postgres:17-alpine`, pinned independently from Mattermost's `postgres:15-alpine`.
- **Identifier rule:** `APPDB_APP_USER` and each entry of `APPDB_DATABASES` must match `^[a-z_][a-z0-9_]{0,62}$`. Reject, never quote-and-hope.
- **Dump schedules:** appdb `02:30`, Mattermost `02:45`, restic `03:00`. Must not overlap.
- **Container scripts are POSIX `sh`**, not bash — the images are Alpine.
- **Commit style:** Conventional Commits, imperative subject ≤ 50 chars, body explains why. Every commit ends with the two trailers used throughout this repo.

## File Structure

| File | Responsibility |
|---|---|
| `tests/compose-guards.sh` | **Create.** Static + rendered assertions about exposure: bind allowlist, `db` services absent from `edge-net`, fail-closed negative test. Runnable locally and from CI. |
| `tests/appdb-integration.sh` | **Create.** Live-container test of the seed contract and both dump modes. Local/manual, not CI (needs image pulls). |
| `docker-compose.yml` | **Modify.** Add `appdb`, `appdb-adminer`, `appdb-dump`, `appdb-net`; add appdb to the backup sources; rewire `mattermost-postgres-dump` onto the shared script. |
| `db/initdb/10-appdb-seed.sh` | **Create.** Role + database seed. Runs only on an empty `PGDATA`. |
| `backup/pg-dump.sh` | **Create** (from `backup/mattermost-db-dump.sh`). Shared scheduler + dumper, two modes. |
| `backup/mattermost-db-dump.sh` | **Delete.** Replaced by `backup/pg-dump.sh`. |
| `backup/backup.sh` | **Modify.** One new `--exclude`. |
| `install.sh` | **Modify.** `db` profile, Tailscale precondition, required-variable probe, secret checks, data dirs, cleanup profile list. |
| `restore.sh` | **Modify.** `db` in the valid profile list. |
| `.env.example` | **Modify.** New `APPDB_*` block. |
| `.github/workflows/ci.yml` | **Modify.** Call `tests/compose-guards.sh`; add `db` to profile renders; syntax-check new scripts. |
| `README.md`, `architecture.md`, `SECURITY.md`, `deployment.md`, `docs/tailscale.md`, `CHANGELOG.md`, `CONTRIBUTING.md` | **Modify.** Documentation chain. |

---

### Task 1: Exposure guard harness

Write the executable statement of "this database can never be reached from the wrong place" **before** the services exist, so the assertions genuinely fail first.

**Files:**
- Create: `tests/compose-guards.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/compose-guards.sh`, exit 0 on pass and non-zero on failure. CI and Task 2 both depend on it. It auto-detects `docker compose` or `podman-compose` via `$COMPOSE_BIN`, defaulting to whichever is on `PATH`.

- [ ] **Step 1: Write the failing test**

Create `tests/compose-guards.sh`:

```sh
#!/usr/bin/env bash
# Exposure guards for the compose files. Runnable locally and from CI:
#
#   ./tests/compose-guards.sh
#
# These assertions encode SECURITY.md's exposure tiers. A published port that
# does not name an interface binds every interface, and a Tier B service that
# joins edge-net becomes reachable by cloudflared -- both are silent failures
# that only show up as an exposed database, so they are tested rather than
# reviewed for.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILURES=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

if [ -n "${COMPOSE_BIN:-}" ]; then
  COMPOSE=$COMPOSE_BIN
elif docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE="podman-compose"
else
  echo "ERROR: need either 'docker compose' or 'podman-compose'." >&2
  exit 2
fi
echo "# using: $COMPOSE"

# --- 1. Bind allowlist -------------------------------------------------------
# Every entry under a `ports:` key must start with an allowed host part.
# Checked against the source files rather than rendered output so the rule holds
# for every value of every variable, not just the ones in .env.example.
bind_offenders() {
  awk '
    /^[[:space:]]*ports:[[:space:]]*$/ { inports = 1; next }
    inports && /^[[:space:]]*#/        { next }
    inports && /^[[:space:]]*-[[:space:]]*/ {
      entry = $0
      sub(/^[[:space:]]*-[[:space:]]*"?/, "", entry)
      if (entry !~ /^(127\.0\.0\.1:|\$\{LAN_IP[:}]|\$\{TAILSCALE_IP[:}])/) {
        printf "%s:%d: %s\n", FILENAME, FNR, $0
      }
      next
    }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { inports = 0 }
  ' "$@"
}

offenders="$(bind_offenders docker-compose.yml compose.dev.yml)"
if [ -n "$offenders" ]; then
  fail "published ports must bind 127.0.0.1, \${LAN_IP…} or \${TAILSCALE_IP…}:"
  printf '%s\n' "$offenders" >&2
else
  pass "every published port names an allowed interface"
fi

# --- 2. Tier B services must not be reachable by cloudflared ------------------
# cloudflared only reaches edge-net. Keeping the db services off it means a
# public hostname created by mistake still cannot route to the database.
edge_members() {
  awk '
    /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); innet = 0 }
    /^[[:space:]]{4}networks:[[:space:]]*$/ { innet = 1; next }
    innet && /^[[:space:]]*-[[:space:]]*edge-net[[:space:]]*$/ { print svc }
    innet && /^[[:space:]]{4}[a-z]/ { innet = 0 }
  ' docker-compose.yml
}

for svc in appdb appdb-adminer appdb-dump; do
  if edge_members | grep -qx "$svc"; then
    fail "$svc is on edge-net; cloudflared could reach it"
  else
    pass "$svc is not on edge-net"
  fi
done

# --- 3. db profile services exist --------------------------------------------
for svc in appdb appdb-adminer appdb-dump; do
  if grep -qE "^  ${svc}:[[:space:]]*$" docker-compose.yml; then
    pass "$svc is defined"
  else
    fail "$svc is not defined in docker-compose.yml"
  fi
done

# --- 4. Fail-closed: empty TAILSCALE_IP must break the db profile ------------
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
sed -E 's/^(TAILSCALE_IP)=.*/\1=/' .env.example > "$scratch/.env.empty"

if env -i PATH="$PATH" HOME="$HOME" \
     $COMPOSE --env-file "$scratch/.env.empty" -f docker-compose.yml \
     --profile db config >/dev/null 2>&1; then
  fail "db profile rendered with an empty TAILSCALE_IP -- the guard is disarmed"
else
  pass "db profile refuses to render with an empty TAILSCALE_IP"
fi

# --- 5. Fail-open check: a set TAILSCALE_IP must render, bound to it ---------
sed -E 's/^(TAILSCALE_IP)=.*/\1=100.64.0.1/' .env.example > "$scratch/.env.set"
rendered="$(env -i PATH="$PATH" HOME="$HOME" \
  $COMPOSE --env-file "$scratch/.env.set" -f docker-compose.yml \
  --profile db config 2>/dev/null)"

if printf '%s' "$rendered" | grep -q '100\.64\.0\.1'; then
  pass "db profile binds the tailscale address when it is set"
else
  fail "db profile did not bind 100.64.0.1 with TAILSCALE_IP set"
fi

if printf '%s' "$rendered" | grep -qE '(^|[^0-9.])0\.0\.0\.0:'; then
  fail "rendered config contains a 0.0.0.0 bind"
else
  pass "rendered config has no 0.0.0.0 bind"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
echo "All compose guards passed."
```

Make it executable:

```bash
chmod +x tests/compose-guards.sh
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./tests/compose-guards.sh`

Expected: FAIL. Checks 3, 4 and 5 fail because `appdb`, `appdb-adminer` and `appdb-dump` do not exist yet and the `db` profile renders nothing. Check 1 and the check-2 assertions pass already — they are regression guards over the current tree.

The exact expected failure lines:

```
FAIL - appdb is not defined in docker-compose.yml
FAIL - appdb-adminer is not defined in docker-compose.yml
FAIL - appdb-dump is not defined in docker-compose.yml
FAIL - db profile rendered with an empty TAILSCALE_IP -- the guard is disarmed
FAIL - db profile did not bind 100.64.0.1 with TAILSCALE_IP set
```

- [ ] **Step 3: Wire it into CI**

In `.github/workflows/ci.yml`, replace the `No unbounded port publishes` step with a call to the script, and add the new scripts to the syntax step. The existing `Shell syntax` step becomes:

```yaml
      - name: Shell syntax
        run: |
          bash -n install.sh
          bash -n restore.sh
          bash -n backup-automount.sh
          bash -n run.sh
          bash -n tests/compose-guards.sh
          bash -n tests/appdb-integration.sh
          sh -n backup/backup.sh
          sh -n backup/pg-dump.sh
          sh -n db/initdb/10-appdb-seed.sh
```

and:

```yaml
      - name: Exposure guards
        run: ./tests/compose-guards.sh
```

Update the ShellCheck step's file list the same way:

```yaml
      - name: ShellCheck (advisory)
        continue-on-error: true
        run: shellcheck install.sh restore.sh run.sh backup-automount.sh
             tests/compose-guards.sh tests/appdb-integration.sh
             backup/backup.sh backup/pg-dump.sh db/initdb/10-appdb-seed.sh
```

And add `db` to the profile renders in `Validate Compose config`:

```yaml
      - name: Validate Compose config
        run: |
          sed -E 's/^(TAILSCALE_IP)=.*/\1=100.64.0.1/' .env.example > .env
          docker compose -f docker-compose.yml config >/dev/null
          docker compose -f docker-compose.yml --profile dns --profile mgmt --profile chat --profile db config >/dev/null
          docker compose -f docker-compose.yml -f compose.dev.yml --profile dns --profile mgmt --profile chat --profile db config >/dev/null
```

Note the changed first line: the base `.env` now needs a `TAILSCALE_IP`, because the `db` profile render would otherwise trip the layer-1 guard. That is the guard working as designed.

- [ ] **Step 4: Commit**

CI will be red until Task 2. That is intentional and is the point of writing the guard first.

```bash
git add tests/compose-guards.sh .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
test: assert the Tier B exposure guards before building them

Encodes the two ways an application database gets exposed by accident: a
published port that names no interface, and a Tier B service joining
edge-net where cloudflared can reach it. Both are silent -- nothing fails
until the database answers from somewhere it should not -- so they get
assertions rather than a review checklist.

Also asserts the fail-closed property itself: rendering the db profile
with an empty TAILSCALE_IP must fail, and rendering it with one set must
bind that address and no wildcard.

Red until the db profile lands in the next commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 2: Compose services and network

**Files:**
- Modify: `docker-compose.yml`
- Test: `tests/compose-guards.sh` (from Task 1)

**Interfaces:**
- Consumes: `tests/compose-guards.sh`.
- Produces: services `appdb` (hostname `appdb`, port 5432 on `appdb-net`), `appdb-adminer`, `appdb-dump`; network `appdb-net`. Task 3 mounts `db/initdb` into `appdb`; Task 4 mounts `backup/pg-dump.sh` into `appdb-dump` and `mattermost-postgres-dump`; Task 5 creates the data directories these bind-mount.

- [ ] **Step 1: Add the three services**

Insert after the `mattermost-postgres-dump` block and before `backup:` in `docker-compose.yml`:

```yaml
  # --- Private tier (Tailscale only) -----------------------------------------
  # Application database for first-party backends. SECURITY.md Tier B: reachable
  # over Tailscale and from appdb-net, never from the LAN and never through
  # Cloudflare. Deliberately separate from mattermost-postgres so the chat
  # profile, its Postgres major version, and its restore blast radius stay
  # independent of application data.
  appdb:
    image: ${APPDB_IMAGE:-docker.io/postgres:17-alpine}
    container_name: appdb
    profiles:
      - db
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - POSTGRES_USER=${APPDB_SUPERUSER:-postgres}
      - POSTGRES_PASSWORD=${APPDB_SUPERUSER_PASSWORD}
      - POSTGRES_DB=postgres
      # Read by db/initdb/10-appdb-seed.sh, which the entrypoint runs only when
      # the data directory is empty.
      - APPDB_APP_USER=${APPDB_APP_USER}
      - APPDB_APP_PASSWORD=${APPDB_APP_PASSWORD}
      - APPDB_DATABASES=${APPDB_DATABASES}
    volumes:
      - ./data/appdb/postgres:/var/lib/postgresql/data
      - ./db/initdb:/docker-entrypoint-initdb.d:ro
    ports:
      # An empty TAILSCALE_IP would render ":5432:5432", which Podman reads as
      # every interface -- putting the database on the LAN. The required-variable
      # form turns that into a hard failure. install.sh checks the same thing
      # earlier with a friendlier message, and CI tests that this still fails.
      - "${TAILSCALE_IP:?TAILSCALE_IP is empty. The db profile is Tailscale-only (SECURITY.md Tier B). Set TAILSCALE_ENABLED=true and run ./install.sh}:${APPDB_PORT:-5432}:5432"
    # Kept for `podman ps` visibility and manual `podman healthcheck run` only;
    # deliberately not used to gate startup ordering - see mattermost above.
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${APPDB_SUPERUSER:-postgres} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - appdb-net

  appdb-adminer:
    image: ${ADMINER_IMAGE:-docker.io/library/adminer:latest}
    container_name: appdb-adminer
    profiles:
      - db
    restart: unless-stopped
    # Plain ordering, not condition: service_healthy - see mattermost above.
    depends_on:
      - appdb
    environment:
      - TZ=${TZ:-UTC}
      - ADMINER_DEFAULT_SERVER=appdb
    ports:
      - "${TAILSCALE_IP:?TAILSCALE_IP is empty. The db profile is Tailscale-only (SECURITY.md Tier B). Set TAILSCALE_ENABLED=true and run ./install.sh}:${ADMINER_PORT:-8081}:8080"
    networks:
      - appdb-net

  appdb-dump:
    image: ${APPDB_IMAGE:-docker.io/postgres:17-alpine}
    container_name: appdb-dump
    profiles:
      - db
    restart: unless-stopped
    # Plain ordering; pg-dump.sh probes with pg_isready and skips a run when the
    # database is not reachable yet.
    depends_on:
      - appdb
    command: ["/bin/sh", "/usr/local/bin/pg-dump.sh"]
    environment:
      - TZ=${TZ:-UTC}
      - PGHOST=appdb
      - PGPORT=5432
      - PGUSER=${APPDB_SUPERUSER:-postgres}
      - PGPASSWORD=${APPDB_SUPERUSER_PASSWORD}
      - PGDATABASE=postgres
      # Every application database plus the role/password globals, because this
      # server hosts an unknown number of databases.
      - DB_DUMP_ALL=true
      - DB_DUMP_HOUR=${APPDB_DUMP_HOUR:-2}
      - DB_DUMP_MINUTE=${APPDB_DUMP_MINUTE:-30}
      - DB_DUMP_KEEP_DAYS=${APPDB_DUMP_KEEP_DAYS:-14}
    volumes:
      - ./backup/pg-dump.sh:/usr/local/bin/pg-dump.sh:ro
      - ./data/appdb/db-dumps:/dumps
    networks:
      - appdb-net
```

- [ ] **Step 2: Add the network**

In the `networks:` block at the bottom of `docker-compose.yml`, after `dns-net`:

```yaml
  # Private tier. internal: true removes egress; the host still reaches in
  # through the published tailscale0 port (verified on rootless Podman 5.8.3
  # with netavark). Future first-party backends join this network and reach the
  # database at appdb:5432 rather than through the published port.
  appdb-net:
    driver: bridge
    internal: true
```

- [ ] **Step 3: Add appdb to the restic sources**

In the `backup` service's `volumes:` list, after the mattermost line:

```yaml
      - ./data/appdb:/sources/appdb:ro
```

- [ ] **Step 4: Run the guards to verify they pass**

Run: `./tests/compose-guards.sh`

Expected: PASS, `All compose guards passed.` All five previously failing lines are now `ok`.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "$(cat <<'EOF'
feat: add the Tier B application database services

Adds appdb, appdb-adminer and appdb-dump behind a new opt-in `db`
profile, on a new internal appdb-net bridge. This is the stack's first
service to actually occupy Tier B; until now the tier existed only in
SECURITY.md.

The services are deliberately absent from edge-net. cloudflared can only
reach services on that network, so a public hostname created by mistake
still cannot route to the database -- the "never through Cloudflare"
requirement is enforced by topology rather than by remembering not to
click something.

mattermost-postgres is untouched: it stays Tier C on db-net behind the
chat profile, keeps its own Postgres 15 pin, and shares nothing with
application data.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 3: Seed script

**Files:**
- Create: `db/initdb/10-appdb-seed.sh`
- Create: `tests/appdb-integration.sh`

**Interfaces:**
- Consumes: `appdb` service from Task 2; env vars `APPDB_APP_USER`, `APPDB_APP_PASSWORD`, `APPDB_DATABASES`, `POSTGRES_USER`.
- Produces: on an empty cluster, a `LOGIN` role named `$APPDB_APP_USER` and one database per `APPDB_DATABASES` entry, each owned by that role, each with `CONNECT` revoked from `PUBLIC`. Task 4's integration test reuses `tests/appdb-integration.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/appdb-integration.sh`. This task adds the seed assertions; Task 4 appends the dump assertions to the same file.

```sh
#!/usr/bin/env bash
# Live-container tests for the appdb seed contract and the shared dump script.
# Not run in CI: it pulls images and starts containers. Run it locally before
# touching db/initdb/ or backup/pg-dump.sh.
#
#   ./tests/appdb-integration.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$PWD"

IMAGE="${APPDB_IMAGE:-docker.io/postgres:17-alpine}"
CT="appdb-itest"
NET="appdb-itest-net"
WORK="$(mktemp -d)"
PGDATA_DIR="$WORK/pgdata"
DUMP_DIR="$WORK/dumps"
SUPERPW="itest-superuser-pw"
APPPW="itest-app-pw"

FAILURES=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

cleanup() {
  podman rm -f "$CT" >/dev/null 2>&1 || true
  podman network rm "$NET" >/dev/null 2>&1 || true
  podman unshare rm -rf "$WORK" >/dev/null 2>&1 || rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$PGDATA_DIR" "$DUMP_DIR"
podman network create --internal "$NET" >/dev/null 2>&1 || true

start_appdb() {
  podman rm -f "$CT" >/dev/null 2>&1 || true
  podman run -d --name "$CT" --network "$NET" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD="$SUPERPW" \
    -e POSTGRES_DB=postgres \
    -e APPDB_APP_USER=appuser \
    -e APPDB_APP_PASSWORD="$APPPW" \
    -e APPDB_DATABASES=alpha,beta \
    -v "$PGDATA_DIR:/var/lib/postgresql/data" \
    -v "$REPO_DIR/db/initdb:/docker-entrypoint-initdb.d:ro" \
    "$IMAGE" >/dev/null
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
podman rm -f "$CT" >/dev/null 2>&1
start_appdb
wait_ready || { fail "appdb never became ready on restart"; exit 1; }

[ "$(q "SELECT 1 FROM pg_database WHERE datname='beta'")" = "" ] \
  && pass "seed did not re-create the dropped database" \
  || fail "seed re-ran on a populated cluster and re-created beta"

[ "$(q "SELECT 1 FROM pg_tables WHERE tablename='itest_marker'")" = "1" ] \
  && pass "existing data survived the restart" || fail "existing data lost"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
echo "All appdb integration checks passed."
```

```bash
chmod +x tests/appdb-integration.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/appdb-integration.sh`

Expected: FAIL. `db/initdb/` does not exist, so the bind mount fails or the directory is empty and nothing is seeded:

```
FAIL - role appuser missing
FAIL - database alpha missing
FAIL - database beta missing
```

- [ ] **Step 3: Write the seed script**

Create `db/initdb/10-appdb-seed.sh`:

```sh
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
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'role') \gexec
SQL
done

log "Seed complete."
```

```bash
chmod +x db/initdb/10-appdb-seed.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./tests/appdb-integration.sh`

Expected: PASS, `All appdb integration checks passed.` — including the two assertions that the seed did **not** re-run on the populated cluster.

Also run: `sh -n db/initdb/10-appdb-seed.sh` — expected: no output.

- [ ] **Step 5: Commit**

```bash
git add db/initdb/10-appdb-seed.sh tests/appdb-integration.sh
git commit -m "$(cat <<'EOF'
feat: seed appdb roles and databases from .env

Creates the application role and one database per APPDB_DATABASES entry
on a fresh cluster, so a clean machine needs no manual CREATE DATABASE
and the credentials are whatever .env says rather than something
generated per install.

Leans on the PostgreSQL entrypoint's empty-PGDATA contract, which is
what makes a restore win: restore.sh repopulates the data directory, so
the seed never runs and cannot overwrite recovered data. The integration
test asserts exactly that by dropping a database and restarting.

Identifiers are validated against ^[a-z_][a-z0-9_]{0,62}$ rather than
quoted, because identifiers cannot be parameterized; passwords are
values and go through psql's :'var' quoting.

CONNECT is revoked from PUBLIC per database, since a shared server would
otherwise let any future role reach every application's data.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 4: Shared logical dump script

**Files:**
- Create: `backup/pg-dump.sh` (from `backup/mattermost-db-dump.sh`)
- Delete: `backup/mattermost-db-dump.sh`
- Modify: `docker-compose.yml` (rewire `mattermost-postgres-dump`)
- Modify: `backup/backup.sh` (one exclude)
- Modify: `tests/appdb-integration.sh` (append dump assertions)

**Interfaces:**
- Consumes: `appdb` from Task 2.
- Produces: `/usr/local/bin/pg-dump.sh` accepting `once` as `$1` for a single run. Env contract: `DB_DUMP_DIR` (default `/dumps`), `DB_DUMP_HOUR`, `DB_DUMP_MINUTE`, `DB_DUMP_KEEP_DAYS`, `DB_DUMP_PREFIX`, `DB_DUMP_ALL`, `DB_DUMP_ON_START`, plus standard `PG*` vars. With `DB_DUMP_ALL=false` it writes `${DB_DUMP_PREFIX}-<ts>.dump` and `${DB_DUMP_PREFIX}-latest.dump`; with `true` it writes `globals-<ts>.sql`, `globals-latest.sql`, `<db>-<ts>.dump` and `<db>-latest.dump` per database.

- [ ] **Step 1: Write the failing test**

Append to `tests/appdb-integration.sh`, immediately before the final `echo` / `FAILURES` block:

```sh
echo "# --- dump: DB_DUMP_ALL=true writes globals plus one file per database ---"
q "CREATE DATABASE beta" >/dev/null
podman run --rm --network "$NET" \
  -e PGHOST="$CT" -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD="$SUPERPW" \
  -e PGDATABASE=postgres -e DB_DUMP_ALL=true -e DB_DUMP_KEEP_DAYS=14 \
  -v "$REPO_DIR/backup/pg-dump.sh:/usr/local/bin/pg-dump.sh:ro" \
  -v "$DUMP_DIR:/dumps" \
  "$IMAGE" /bin/sh /usr/local/bin/pg-dump.sh once >/dev/null 2>&1

ls "$DUMP_DIR"/globals-latest.sql >/dev/null 2>&1 \
  && pass "globals-latest.sql written" || fail "globals-latest.sql missing"
for db in alpha beta postgres; do
  ls "$DUMP_DIR/$db-latest.dump" >/dev/null 2>&1 \
    && pass "$db-latest.dump written" || fail "$db-latest.dump missing"
done
ls "$DUMP_DIR"/*.tmp >/dev/null 2>&1 \
  && fail "temp files left behind" || pass "no temp files left behind"

grep -q 'CREATE ROLE appuser' "$DUMP_DIR/globals-latest.sql" \
  && pass "globals dump carries the application role" \
  || fail "globals dump does not contain the application role"

echo "# --- dump: DB_DUMP_ALL=false reproduces the Mattermost filenames ---"
MM_DIR="$WORK/mm-dumps"; mkdir -p "$MM_DIR"
podman run --rm --network "$NET" \
  -e PGHOST="$CT" -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD="$SUPERPW" \
  -e PGDATABASE=alpha -e DB_DUMP_ALL=false -e DB_DUMP_PREFIX=mattermost \
  -e DB_DUMP_KEEP_DAYS=14 \
  -v "$REPO_DIR/backup/pg-dump.sh:/usr/local/bin/pg-dump.sh:ro" \
  -v "$MM_DIR:/dumps" \
  "$IMAGE" /bin/sh /usr/local/bin/pg-dump.sh once >/dev/null 2>&1

ls "$MM_DIR/mattermost-latest.dump" >/dev/null 2>&1 \
  && pass "mattermost-latest.dump written (single-database mode unchanged)" \
  || fail "mattermost-latest.dump missing"
ls "$MM_DIR"/mattermost-[0-9]*.dump >/dev/null 2>&1 \
  && pass "timestamped mattermost dump written" \
  || fail "timestamped mattermost dump missing"
ls "$MM_DIR"/globals-*.sql >/dev/null 2>&1 \
  && fail "single-database mode wrote globals (it must not)" \
  || pass "single-database mode wrote no globals"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/appdb-integration.sh`

Expected: the seed checks still pass; the new dump checks FAIL because `backup/pg-dump.sh` does not exist:

```
FAIL - globals-latest.sql missing
FAIL - alpha-latest.dump missing
FAIL - mattermost-latest.dump missing
```

- [ ] **Step 3: Write the shared script**

```bash
git mv backup/mattermost-db-dump.sh backup/pg-dump.sh
```

Then replace the contents of `backup/pg-dump.sh` with:

```sh
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
```

- [ ] **Step 4: Rewire the Mattermost dump sidecar**

In `docker-compose.yml`, in the `mattermost-postgres-dump` service, change the `command:` and the env/volume lines. The user-facing `.env` keys keep their names and are mapped onto the generic contract, so existing installs see no change:

```yaml
    command: ["/bin/sh", "/usr/local/bin/pg-dump.sh"]
    environment:
      - TZ=${TZ:-UTC}
      - PGHOST=mattermost-postgres
      - PGPORT=5432
      - PGUSER=mmuser
      - PGPASSWORD=${MATTERMOST_DB_PASSWORD}
      - PGDATABASE=mattermost
      # Single-database mode. With this prefix the filenames are byte-for-byte
      # what the old mattermost-db-dump.sh produced.
      - DB_DUMP_ALL=false
      - DB_DUMP_PREFIX=mattermost
      - DB_DUMP_HOUR=${MATTERMOST_DB_DUMP_HOUR:-2}
      - DB_DUMP_MINUTE=${MATTERMOST_DB_DUMP_MINUTE:-45}
      - DB_DUMP_KEEP_DAYS=${MATTERMOST_DB_DUMP_KEEP_DAYS:-14}
    volumes:
      - ./backup/pg-dump.sh:/usr/local/bin/pg-dump.sh:ro
      - ./data/mattermost/db-dumps:/dumps
```

- [ ] **Step 5: Add the appdb exclude to backup.sh**

In `backup/backup.sh`, extend the `restic backup` invocation:

```sh
restic backup "$SRC_ROOT" \
  --exclude "/sources/mattermost/db-dumps/*.tmp" \
  --exclude "/sources/appdb/db-dumps/*.tmp" \
  --host "$RESTIC_HOST" \
  --tag localcloud
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./tests/appdb-integration.sh`

Expected: PASS, `All appdb integration checks passed.` — both dump modes, including the assertion that single-database mode writes no globals and reproduces the Mattermost filenames.

Run: `sh -n backup/pg-dump.sh && sh -n backup/backup.sh` — expected: no output.

Run: `./tests/compose-guards.sh` — expected: still `All compose guards passed.`

- [ ] **Step 7: Commit**

```bash
git add backup/pg-dump.sh backup/backup.sh docker-compose.yml tests/appdb-integration.sh
git commit -m "$(cat <<'EOF'
refactor: share one logical dump script between both databases

appdb needs the same scheduler, atomic publish, and retention that
mattermost-postgres-dump already had, so the script is generalized
rather than copied. Its env contract becomes generic and compose maps
each service onto it; the user-facing MATTERMOST_DB_DUMP_* keys keep
their names, so existing installs see no change.

The new DB_DUMP_ALL=true mode adds what a shared server needs and a
single-purpose one did not: pg_dumpall --globals-only for roles and
their passwords, then one dump per database discovered at run time.
Without the globals a restored database exists but nothing can log in
to it.

The integration test pins the Mattermost path by asserting that
DB_DUMP_ALL=false with DB_DUMP_PREFIX=mattermost still produces exactly
mattermost-<ts>.dump and mattermost-latest.dump, and writes no globals.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 5: Installer and restore integration

**Files:**
- Modify: `install.sh:47-67` (`normalize_profiles`), `install.sh:74-79` (add probe alongside), `install.sh:183-190` (per-profile checks), `install.sh:204-212` (data dirs), `install.sh:310` (cleanup profile list)
- Modify: `restore.sh:32-53` (`normalize_profiles`)

**Interfaces:**
- Consumes: the `db` profile from Task 2.
- Produces: an installer that refuses to proceed when `db` is enabled without Tailscale or without its secrets, creates `./data/appdb/postgres` and `./data/appdb/db-dumps`, and includes `--profile db` in the pre-start cleanup.

- [ ] **Step 1: Accept `db` as a profile in both scripts**

In `install.sh`, in `normalize_profiles`:

```sh
    case "$profile" in
      dns|mgmt|chat|db) ;;
      *)
        fail "Invalid LOCALCLOUD_PROFILES entry '${profile}'. Use comma-separated values from: dns, mgmt, chat, db."
        ;;
    esac
```

In `restore.sh`, in `normalize_profiles`:

```sh
    case "$profile" in
      dns|mgmt|chat|db) ;;
      *)
        echo "ERROR: invalid LOCALCLOUD_PROFILES entry '${profile}'. Use comma-separated values from: dns, mgmt, chat, db." >&2
        exit 1
        ;;
    esac
```

- [ ] **Step 2: Add the required-variable capability probe**

In `install.sh`, immediately after `require_compose_profile_support()`:

```sh
# The db profile's port mapping uses the required-variable form
# "${TAILSCALE_IP:?...}" so that an empty value is a hard failure instead of a
# bind on every interface. A podman-compose that does not implement that form
# would substitute empty and silently disarm the guard, so probe for it the same
# way profile support is probed rather than comparing version strings.
require_compose_required_var_support() {
  profile_enabled db || return 0
  local probe
  probe="$(mktemp -d)"
  cat > "$probe/docker-compose.yml" <<'PROBE'
services:
  probe:
    image: localhost/localcloud-probe
    ports:
      - "${LOCALCLOUD_PROBE_UNSET:?required}:1:1"
PROBE
  : > "$probe/.env"
  if ( cd "$probe" && "$PODMAN_COMPOSE_BIN" -f docker-compose.yml config ) >/dev/null 2>&1; then
    rm -rf "$probe"
    fail "$PODMAN_COMPOSE_BIN does not implement the \${VAR:?message} form, so the db profile's Tailscale-only bind guard would silently fall back to binding every interface. Upgrade podman-compose (for example 'pipx install podman-compose') or remove 'db' from LOCALCLOUD_PROFILES."
  fi
  rm -rf "$probe"
}
```

- [ ] **Step 3: Add the per-profile preconditions**

In `install.sh`, replace the per-profile configuration block:

```sh
# Per-profile required configuration.
if profile_enabled mgmt; then require_env_value PODMAN_SOCKET_PATH; fi
if profile_enabled chat; then
  require_env_value MATTERMOST_DB_PASSWORD
  require_env_value MATTERMOST_SUBDOMAIN
fi
if profile_enabled db; then
  # Tier B is defined by its transport. Without Tailscale there is no address to
  # bind to, and the compose mapping would fall back to every interface -- which
  # is exactly the exposure this tier exists to prevent. Fail before anything
  # starts, with the fix rather than just the symptom.
  if [ "$TAILSCALE_ENABLED" != "true" ]; then
    fail "LOCALCLOUD_PROFILES includes 'db', but TAILSCALE_ENABLED is not 'true'. The application database is a Private (Tier B) service: it is reachable only over Tailscale and must never be published to the LAN or through Cloudflare. Complete deployment.md section 13 (Private Tier), set TAILSCALE_ENABLED=true, then run ./install.sh again."
  fi
  require_env_value APPDB_SUPERUSER_PASSWORD
  require_env_value APPDB_APP_USER
  require_env_value APPDB_APP_PASSWORD
  require_env_value APPDB_DATABASES
  require_compose_required_var_support
fi
```

Note the ordering constraint: this block reads `$TAILSCALE_ENABLED`, which is assigned at `install.sh:167`, and it must run **before** `check_tailscale` so the operator gets the `db`-specific message rather than a generic Tailscale one. Place it where the existing per-profile block already sits (after the profile parsing at line 180, before `check_tailscale` at line 190).

- [ ] **Step 4: Create the data directories**

In `install.sh`, extend the `mkdir -p` call:

```sh
info "Creating private data directories"
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf} \
         ./data/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes,postgres,db-dumps} \
         ./data/appdb/{postgres,db-dumps}
```

No `podman unshare chown` entry is added for `appdb`. The PostgreSQL entrypoint starts as container-root and chowns `PGDATA` itself, which is why there is no such line for `./data/mattermost/postgres` either. The dump sidecar overrides the command and therefore also runs as container-root, so the host-owned `db-dumps` directory is writable.

- [ ] **Step 5: Include the profile in the pre-start cleanup**

In `install.sh`, extend the cleanup line so a disabled `db` profile does not leave containers running:

```sh
if ! "$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" --profile dns --profile mgmt --profile chat --profile db down --remove-orphans; then
```

There is a wrinkle: that cleanup names every profile regardless of what is enabled, so it renders the `db` service and trips the layer-1 guard when `TAILSCALE_IP` is empty. The existing code already tolerates a non-zero exit here with a warning, so cleanup still works, but the message would be confusing. Guard it by only adding `--profile db` when a tailscale address is known:

```sh
CLEANUP_PROFILE_ARGS=(--profile dns --profile mgmt --profile chat)
if [ -n "$TAILSCALE_IP" ]; then
  CLEANUP_PROFILE_ARGS+=(--profile db)
fi
info "Stopping any existing LocalCloud containers before applying selected profiles"
if ! "$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" "${CLEANUP_PROFILE_ARGS[@]}" down --remove-orphans; then
  info "WARNING: pre-start cleanup exited non-zero (normal when nothing was running)."
fi
```

- [ ] **Step 6: Verify**

Run: `bash -n install.sh && bash -n restore.sh` — expected: no output.

Run: `shellcheck install.sh restore.sh` — expected: no new findings beyond those already present on `main`.

Run: `./tests/compose-guards.sh` — expected: `All compose guards passed.`

`install.sh` itself cannot be executed on macOS (it requires `loginctl`), so its behavior is verified on the host in Task 8. The fail-closed property it enforces is independently covered by the layer-1 assertions in `tests/compose-guards.sh`, which do run here.

- [ ] **Step 7: Commit**

```bash
git add install.sh restore.sh
git commit -m "$(cat <<'EOF'
feat: gate the db profile on Tailscale in the installer

The db profile's bind depends on TAILSCALE_IP being real. Enabling the
profile without Tailscale would leave compose to fail on its own, which
happens late and explains nothing, so the installer now refuses up front
and names the fix.

Also probes for ${VAR:?} support instead of trusting it. A podman-compose
without that form would substitute empty and turn the port mapping into a
bind on every interface -- the guard would look present in the file while
doing nothing. Same reasoning, and same shape, as the existing --profile
capability probe.

The pre-start cleanup only names --profile db once an address is known,
so the teardown path does not trip the guard it is protecting.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 6: Environment template

**Files:**
- Modify: `.env.example`

**Interfaces:**
- Consumes: variable names from Tasks 2 and 5.
- Produces: `.env.example` containing every key the `db` profile requires. `tests/compose-guards.sh` reads this file, so it must render the `db` profile once `TAILSCALE_IP` is substituted.

- [ ] **Step 1: Add the appdb block**

In `.env.example`, extend the `LOCALCLOUD_PROFILES` comment to document the new profile:

```sh
#   db   - Application database: PostgreSQL + Adminer for your own backends.
#          Private (Tier B): reachable only over Tailscale, never through
#          Cloudflare. Requires TAILSCALE_ENABLED=true and the APPDB_* values
#          below.
```

Then add a new block after the Mattermost dump settings:

```sh
# --- Application database (db profile) --------------------------------------
# Private (Tier B) PostgreSQL for your own backend applications, plus Adminer.
# Reachable only over Tailscale: the port binds ${TAILSCALE_IP} and the services
# are deliberately kept off the Cloudflare tunnel's network. Requires
# TAILSCALE_ENABLED=true; install.sh refuses the db profile without it.
#
# Use hex, NOT base64 - base64's + / = characters break the postgres:// string:
#   openssl rand -hex 32
APPDB_SUPERUSER=postgres
APPDB_SUPERUSER_PASSWORD=change-me-run-openssl-rand-hex-32
APPDB_APP_USER=appuser
APPDB_APP_PASSWORD=change-me-run-openssl-rand-hex-32
# Comma-separated databases created on a FRESH cluster only, each owned by
# APPDB_APP_USER. Names must match ^[a-z_][a-z0-9_]{0,62}$. Adding a name later
# does not create it on an existing cluster - see deployment.md section 14.
APPDB_DATABASES=app1,app2
APPDB_PORT=5432
ADMINER_PORT=8081

# Logical dump schedule for the application database. Runs before Mattermost's
# 02:45 dump and the 03:00 restic snapshot.
APPDB_DUMP_HOUR=2
APPDB_DUMP_MINUTE=30
APPDB_DUMP_KEEP_DAYS=14
```

Add to the optional image refs block:

```sh
APPDB_IMAGE=docker.io/postgres:17-alpine
ADMINER_IMAGE=docker.io/library/adminer:latest
```

- [ ] **Step 2: Verify the guards still pass**

Run: `./tests/compose-guards.sh`

Expected: `All compose guards passed.` Checks 4 and 5 now exercise the real `.env.example` values — check 4 blanks `TAILSCALE_IP` and expects failure, check 5 sets it to `100.64.0.1` and expects that address in the rendered output.

Run: `podman-compose -f docker-compose.yml config >/dev/null` with a `.env` copied from `.env.example` — expected: succeeds (the base profile does not render `db`).

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "$(cat <<'EOF'
feat: document the db profile's settings in .env.example

Names every value the db profile requires, and says at the point of
configuration that it is Tailscale-only and that install.sh will refuse
the profile without TAILSCALE_ENABLED=true.

Repeats the hex-not-base64 warning next to both new passwords, for the
same reason MATTERMOST_DB_PASSWORD carries it: base64's + / = characters
break a postgres:// connection string.

States that APPDB_DATABASES only takes effect on a fresh cluster, since
that is the surprising half of the seed contract.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 7: Documentation chain

**Files:**
- Modify: `README.md`, `architecture.md`, `SECURITY.md`, `deployment.md`, `docs/tailscale.md`, `CHANGELOG.md`, `CONTRIBUTING.md`

**Interfaces:**
- Consumes: everything from Tasks 2-6.
- Produces: no code interface. `deployment.md` section 14 becomes the operator-facing reference the other documents link to.

- [ ] **Step 1: README.md**

Add to the services table:

```markdown
| PostgreSQL + Adminer (`db` profile) | application database for your own backends | Tailscale only, never Cloudflare |
```

Add to the optional profiles table:

```markdown
| `db` | PostgreSQL + Adminer + logical dumps - Private (Tier B). Requires `TAILSCALE_ENABLED=true`; the installer refuses the profile without it. | off |
```

In **Requirements**, change the Tailscale line to note it is mandatory for `db`:

```markdown
- Optional: Tailscale on the host for the Private (Tier B) transport - **required** if you enable the `db` profile
```

In the `LOCALCLOUD_PROFILES` paragraph, extend the valid-values sentence to `dns`, `mgmt`, `chat`, and `db`, and add:

```markdown
The `db` profile additionally requires `TAILSCALE_ENABLED=true` plus `APPDB_SUPERUSER_PASSWORD`, `APPDB_APP_USER`, `APPDB_APP_PASSWORD`, and `APPDB_DATABASES`. It publishes PostgreSQL and Adminer on the tailscale0 address only; neither is ever routed through Cloudflare Tunnel. See [deployment.md section 14](deployment.md).
```

In **Security Model**, replace the Tier B bullet:

```markdown
- **Private (Tier B)** - reachable only through Tailscale; services bind to the tailscale0 address, never to all interfaces. The `db` profile's PostgreSQL and Adminer are the first services in this tier.
```

- [ ] **Step 2: architecture.md**

Network Model table, add a row:

```markdown
| `appdb-net` | application database and Adminer; `internal: true`, no egress |
```

Exposure Model, replace the Tier B and Tier C bullets:

```markdown
- **Tier B (Private)** - reachable only through Tailscale, bound to the tailscale0 address: the `db` profile's PostgreSQL and Adminer. Gitea SSH moves here from its LAN bind later.
- **Tier C (Internal)** - never published: mattermost-postgres, appdb-dump, backup (`network_mode: none`), Portainer (mgmt profile).
```

Data Model, add `- ./data/appdb` to the important paths list.

Backup Model, add a step between the current 2 and 3:

```markdown
3. When `db` is enabled, write `pg_dumpall --globals-only` plus one logical dump per application database to `./data/appdb/db-dumps`.
```

and renumber the rest.

Optional Services, add:

```markdown
- `LOCALCLOUD_PROFILES=db` enables the application database (PostgreSQL + Adminer + logical dumps). Requires the Tailscale transport.
```

- [ ] **Step 3: SECURITY.md**

Exposure Tiers table, replace the Tier B row:

```markdown
| B | Private | Tailscale (tailnet) | tailscale0 address only | tailnet membership + ACL + service auth | appdb (PostgreSQL), appdb-adminer* |
```

Under **Tier B - Private**, replace the planned-services line:

```markdown
- Implemented services in this tier: the `db` profile's PostgreSQL (`appdb`) and Adminer (`appdb-adminer`). They bind `${TAILSCALE_IP}` through compose's required-variable form, so an empty address fails the render instead of falling back to every interface. `install.sh` refuses the profile unless `TAILSCALE_ENABLED=true`, and CI asserts both behaviors.
- These services are deliberately absent from `edge-net`. `cloudflared` reaches only that network, so a public hostname created by mistake still cannot route to the database.
- Adminer has no accounts of its own; the PostgreSQL credentials are the only authentication. Tailnet membership is therefore the outer perimeter, not a convenience.
- Still planned for this tier: Gitea SSH, moved from its LAN bind.
```

Under **CI Enforcement**, replace the paragraph:

```markdown
`docker-compose.yml` and `compose.dev.yml` must never publish a port whose host part is anything other than `127.0.0.1`, `${LAN_IP…}`, or `${TAILSCALE_IP…}`. `tests/compose-guards.sh` enforces that, asserts that no Tier B service joins `edge-net`, and asserts the fail-closed property directly: rendering the `db` profile with an empty `TAILSCALE_IP` must fail. CI runs the script on every push.
```

Under **Secrets**, add to the generation list:

```sh
openssl rand -hex 32      # APPDB_SUPERUSER_PASSWORD and APPDB_APP_PASSWORD if enabling --profile db
```

Under **Host Firewall**, add after the existing note:

```markdown
The `db` profile needs no new ufw rule beyond `sudo ufw allow in on tailscale0`: PostgreSQL and Adminer bind the tailscale0 address, so the default-deny public interface already covers them.
```

- [ ] **Step 4: deployment.md — new section 14**

Append after section 13:

````markdown
## 14. Application Database (`db` Profile)

Optional. A general-purpose PostgreSQL for your own backend applications, plus
Adminer, plus a logical-dump sidecar. This is a Private (Tier B) service: it is
reachable over Tailscale and from the `appdb-net` compose network, and it is
never published to the LAN or routed through Cloudflare Tunnel.

Separate from `mattermost-postgres` on purpose. That one stays internal to the
`chat` profile, keeps its own PostgreSQL 15 pin, and shares no data, no network,
and no restore blast radius with your application databases.

### Prerequisites

Section 13 first. The `db` profile is refused without it:

```
ERROR: LOCALCLOUD_PROFILES includes 'db', but TAILSCALE_ENABLED is not 'true'.
```

That is deliberate. Without a tailscale0 address the port mapping has nothing to
bind to and would fall back to every interface, putting the database on the LAN.

### Enable

In `.env`:

```sh
LOCALCLOUD_PROFILES=db          # or e.g. dns,chat,db
TAILSCALE_ENABLED=true

APPDB_SUPERUSER_PASSWORD=<openssl rand -hex 32>
APPDB_APP_USER=appuser
APPDB_APP_PASSWORD=<openssl rand -hex 32>
APPDB_DATABASES=app1,app2
```

Hex, not base64: `+`, `/`, and `=` break a `postgres://` connection string.

Then:

```sh
./install.sh
```

### What The First Start Creates

On a **fresh** cluster only, `db/initdb/10-appdb-seed.sh` creates the
`APPDB_APP_USER` role and one database per `APPDB_DATABASES` entry, each owned by
that role, each with `CONNECT` revoked from `PUBLIC`.

"Fresh" means `./data/appdb/postgres` is empty. This is what makes a restore win
over the seed: `./restore.sh` repopulates that directory, so the seed does not
run and cannot overwrite recovered data.

The consequences are worth stating plainly:

- **Adding a name to `APPDB_DATABASES` later does nothing.** The cluster is no
  longer empty. Create it by hand:
  ```sh
  podman exec -it appdb psql -U postgres -c 'CREATE DATABASE app3 OWNER appuser'
  ```
- **Changing `APPDB_APP_PASSWORD` later does not change the database.** `.env`
  seeds; it does not reconcile. Rotate both sides:
  ```sh
  podman exec -it appdb psql -U postgres \
    -c "ALTER ROLE appuser PASSWORD 'the-new-password'"
  # then set the same value in .env and re-run ./install.sh
  ```

### Connect

From any device on your tailnet:

```sh
tailscale ip -4                 # on the server: the address the database binds
psql "postgresql://appuser@<tailscale-ip>:5432/app1"
```

A GUI client (DBeaver, TablePlus, DataGrip) uses the same values: host is the
server's `100.x` tailscale address, port `5432`, user `APPDB_APP_USER`, password
`APPDB_APP_PASSWORD`.

Adminer: `http://<tailscale-ip>:8081`, pre-pointed at the `appdb` server.
Adminer has no accounts of its own — the PostgreSQL credentials are the only
authentication, which is why it lives behind the tailnet.

From a container in this compose project, join `appdb-net` and use the service
name; this never touches the published port:

```yaml
    environment:
      - DATABASE_URL=postgres://appuser:${APPDB_APP_PASSWORD}@appdb:5432/app1
    networks:
      - appdb-net
```

### Verify

```sh
podman ps --filter name=appdb --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
ss -tlnp | grep 5432
```

The listening address must be the `100.x` tailscale address. **If you ever see
`0.0.0.0:5432` or `*:5432`, stop and fix it** — the database is on your LAN.

Confirm the negative case too, from a LAN host that is not on the tailnet:

```sh
nc -z -w3 <server-lan-ip> 5432 && echo "EXPOSED - investigate" || echo "not reachable from LAN, correct"
```

Check the dumps:

```sh
ls -lh ./data/appdb/db-dumps/
podman exec appdb-dump /usr/local/bin/pg-dump.sh once
```

Expect `globals-latest.sql` plus one `<database>-latest.dump` per database.

### Restore

**Normal path** — the raw data directory, via the usual helper. It restores
every service's data, keeps your current data aside, and honors the profiles in
`.env`:

```sh
./restore.sh              # latest snapshot
./restore.sh <id>         # a specific snapshot from `restic snapshots`
```

**Logical path** — when the raw data directory is damaged. The raw `PGDATA` is
copied file-level while PostgreSQL may be writing, so it carries a torn-copy
risk; the logical dumps do not. Load the globals first, or the databases will
exist with nobody able to log in to them:

```sh
podman-compose -f docker-compose.yml --profile db down
podman unshare rm -rf ./data/appdb/postgres
mkdir -p ./data/appdb/postgres
podman-compose -f docker-compose.yml --profile db up -d appdb
# wait for it to accept connections
podman exec -i appdb psql -U postgres < ./data/appdb/db-dumps/globals-latest.sql
for db in app1 app2; do
  podman exec -i appdb psql -U postgres -c "CREATE DATABASE $db OWNER appuser"
  podman exec -i appdb pg_restore -U postgres -d "$db" \
    < "./data/appdb/db-dumps/$db-latest.dump"
done
```

Restoring the globals brings back role passwords as stored hashes, so
applications keep working with the credentials already in their configuration.

### Rollback

```sh
# in .env: remove `db` from LOCALCLOUD_PROFILES
./install.sh
```

The installer stops the profile's containers. `./data/appdb` is left in place —
delete it by hand once you are sure you want the data gone.
````

Also update these existing places in `deployment.md`:

- **Section 2**, valid profiles sentence: add `db`, and note it requires `TAILSCALE_ENABLED=true`.
- **Section 4** (firewall), after the existing note: `The db profile needs no extra rule; PostgreSQL and Adminer bind the tailscale0 address, covered by \`sudo ufw allow in on tailscale0\`.`
- **Section 8** (verify), profile services list: add `appdb` + `appdb-adminer` + `appdb-dump` (`db`).
- **Section 13**, step 3, after the `TAILSCALE_ENABLED=true` block: `The \`db\` profile (section 14) depends on this section being complete; the installer refuses it otherwise.`

- [ ] **Step 5: docs/tailscale.md**

Change the status line at the top:

```markdown
Status: **Phase V3 implemented** - the application database (`db` profile) is the
first Tier B service; see [deployment.md section 14](../deployment.md#14-application-database-db-profile).
Phase V1 (host install) is a manual step, see
[deployment.md section 13](../deployment.md#13-private-tier-tailscale).
Phase V4 (SSH tightening) remains open. Policy context:
[SECURITY.md](../SECURITY.md).
```

Replace the Phase V3 section body:

```markdown
### Phase V3 - First Tier B Service (PostgreSQL) — implemented

Delivered as the `db` profile: `appdb` (PostgreSQL), `appdb-adminer`, and
`appdb-dump`. Binds `${TAILSCALE_IP}` through compose's required-variable form,
lives on `appdb-net` (`internal: true`), stays off `edge-net` so `cloudflared`
cannot reach it, and reuses the backup pattern (logical dump sidecar plus a
read-only restic mount). Design:
`docs/superpowers/specs/2026-08-28-appdb-tier-b-design.md`.
```

Fix the two dead cross-references: this file points at "deployment.md section 11"
for the Private Tier in the status header and in Phase V1, but that section is
**13** — section 11 is *Recovering A Wedged Stack*.

- [ ] **Step 6: CONTRIBUTING.md**

Update the checklist command block:

```sh
  bash -n install.sh
  bash -n restore.sh
  bash -n run.sh
  sh -n backup/backup.sh
  sh -n backup/pg-dump.sh
  sh -n db/initdb/10-appdb-seed.sh
  ./tests/compose-guards.sh
  podman-compose -f docker-compose.yml config
  podman-compose -f docker-compose.yml --profile dns --profile mgmt --profile chat --profile db config
  git diff --check
```

Add a line under **Pull Request Checklist**:

```markdown
- New services must declare an exposure tier (SECURITY.md) and pass `./tests/compose-guards.sh`.
```

- [ ] **Step 7: CHANGELOG.md**

Under `## [Unreleased]` → `### Added`, at the top:

```markdown
- Application database behind a new opt-in `db` profile: PostgreSQL
  (`appdb`), Adminer (`appdb-adminer`), and a logical-dump sidecar
  (`appdb-dump`), for first-party backend applications. This is the stack's
  first Private (Tier B) service - it binds the tailscale0 address only, lives
  on a new `internal: true` `appdb-net`, and is deliberately kept off
  `edge-net` so `cloudflared` cannot route to it even if a public hostname is
  created by mistake. Roles and databases are seeded from `.env` on a fresh
  cluster only, so a restore always wins over the seed. Separate from
  `mattermost-postgres` in every respect, including its image pin.
- `tests/compose-guards.sh` - exposure assertions runnable locally and in CI:
  published ports must name an allowed interface, Tier B services must not join
  `edge-net`, and rendering the `db` profile with an empty `TAILSCALE_IP` must
  fail.
- `tests/appdb-integration.sh` - live-container tests for the seed contract
  (including that it does not re-run on a populated cluster) and both dump modes.
```

Under `### Changed`:

```markdown
- `backup/mattermost-db-dump.sh` is now `backup/pg-dump.sh`, shared by both
  dump sidecars. Its environment contract is generic and compose maps each
  service onto it; the user-facing `MATTERMOST_DB_DUMP_*` keys are unchanged.
  A new `DB_DUMP_ALL=true` mode dumps `pg_dumpall --globals-only` plus every
  database, which a server hosting an unknown number of application databases
  needs and a single-purpose one did not.
- `install.sh` and `restore.sh` accept the `db` profile. The installer refuses
  it unless `TAILSCALE_ENABLED=true`, and probes that podman-compose implements
  `${VAR:?message}` before relying on it as an exposure guard.
```

Under `### Fixed`:

```markdown
- `docs/tailscale.md` linked to "deployment.md section 11" for the Private Tier
  in two places; that section is 13, and 11 is *Recovering A Wedged Stack*.
```

- [ ] **Step 8: Verify the documentation is consistent**

Run:

```bash
grep -rn "section 11" docs/tailscale.md          # expect: no Private Tier hits
grep -rn "dns, mgmt, chat" --include=*.md --include=*.sh . | grep -v CHANGELOG
grep -rn "mattermost-db-dump" . --exclude-dir=.git
./tests/compose-guards.sh
```

Expected: the first returns nothing; the second returns nothing that still omits `db`; the third returns only `CHANGELOG.md`; the fourth passes.

- [ ] **Step 9: Commit**

```bash
git add README.md architecture.md SECURITY.md deployment.md docs/tailscale.md CHANGELOG.md CONTRIBUTING.md
git commit -m "$(cat <<'EOF'
docs: document the Tier B application database

Adds deployment.md section 14 as the operator reference: prerequisites,
enabling, what the first start creates, how to connect from the tailnet
and from a sibling container, verification including the negative test
from a LAN host, and both restore paths.

States the two surprising consequences of the seed contract rather than
leaving them to be discovered: adding a name to APPDB_DATABASES later
does nothing, and changing APPDB_APP_PASSWORD later does not reach the
database. Both get the command that does work.

Marks Tailscale Phase V3 implemented and fixes its two links to
"deployment.md section 11" for the Private Tier -- that section is 13;
11 is Recovering A Wedged Stack.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01C2mfdCEGWsXti1oyLWMvPJ
EOF
)"
```

---

### Task 8: Host verification

The only task that cannot run on the development machine. `install.sh` requires
`loginctl`, and the Tailscale bind cannot be exercised without a tailnet.

**Files:** none — this task produces evidence, not changes.

**Interfaces:**
- Consumes: everything from Tasks 1-7, deployed to the Ubuntu host.
- Produces: a pass/fail record for each check below. Any failure returns to the relevant task.

- [ ] **Step 1: Deploy the branch to the host**

```sh
cd ~/localcloud-stack
git fetch origin && git checkout feat/appdb-tier-b && git pull
```

- [ ] **Step 2: Verify the installer refuses the profile without Tailscale**

Temporarily set `LOCALCLOUD_PROFILES=db` and `TAILSCALE_ENABLED=false` in `.env`, then:

```sh
./install.sh
```

Expected: fails with the `db`/`TAILSCALE_ENABLED` message, and **no container starts**. Confirm with `podman ps --filter name=appdb` returning nothing.

- [ ] **Step 3: Verify compose refuses it too, bypassing the installer**

```sh
TAILSCALE_IP= podman-compose -f docker-compose.yml --profile db config
```

Expected: non-zero exit, message naming `TAILSCALE_IP`. This is the layer that protects a hand-typed command.

- [ ] **Step 4: Install for real**

Set `TAILSCALE_ENABLED=true` and the four `APPDB_*` values, then:

```sh
./install.sh
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected: `appdb`, `appdb-adminer`, `appdb-dump` running, ports showing the `100.x` address.

- [ ] **Step 5: Verify the bind**

```sh
ss -tlnp | grep -E '5432|8081'
```

Expected: the `100.x` tailscale address only. **A `0.0.0.0` or `*` here is a failure** — stop and return to Task 2.

- [ ] **Step 6: Verify reachability, both directions**

From an enrolled device on a foreign network:

```sh
psql "postgresql://appuser@<tailscale-ip>:5432/app1" -c 'SELECT current_database()'
```

Expected: connects.

From a LAN host that is not on the tailnet:

```sh
nc -z -w3 <server-lan-ip> 5432 && echo "EXPOSED" || echo "not reachable, correct"
```

Expected: `not reachable, correct`.

- [ ] **Step 7: Verify the seed and the dumps**

```sh
podman exec appdb psql -U postgres -c '\l'
podman exec appdb-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/appdb/db-dumps/
```

Expected: the seeded databases exist; `globals-latest.sql` and one
`<db>-latest.dump` per database are present.

- [ ] **Step 8: Verify Mattermost dumps did not regress**

Only if the `chat` profile is enabled:

```sh
podman exec mattermost-postgres-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/mattermost/db-dumps/
```

Expected: a new `mattermost-<ts>.dump` and a refreshed `mattermost-latest.dump`,
with no `globals-*.sql` in that directory.

- [ ] **Step 9: Verify the backup picks it up**

```sh
podman restart backup
podman exec backup /usr/local/bin/backup.sh
podman logs backup 2>&1 | tail -20
```

Expected: `Backup finished OK.` Then confirm the new source is in the snapshot:

```sh
export RESTIC_PASSWORD='<from .env>'
export RESTIC_REPOSITORY=/mnt/usb-disk/restic-repo
restic ls latest /sources/appdb | head
```

Expected: the appdb data and dump files are listed.

- [ ] **Step 10: Verify restart survival**

```sh
sudo reboot
```

After it returns:

```sh
podman ps --filter name=appdb --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
ss -tlnp | grep 5432
```

Expected: all three containers back up, still bound to the `100.x` address.

- [ ] **Step 11: Record the results and open the PR**

```bash
git push -u origin feat/appdb-tier-b
gh pr create --title "feat: add the Tier B application database" --body "..."
```

The PR body should carry the Task 8 results, since they cannot be reproduced by
CI.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: Services and Network →
Task 2; Fail-Closed Exposure Guard layers 1/2/3 → Tasks 2/5/1; Seed Model →
Task 3; Backup Model file-level, logical dumps, shared script, restore →
Task 4 and Task 7 section 14; Installer Changes → Task 5; Documentation
Changes → Task 7; Testing (automated) → Tasks 1, 3, 4; Testing (manual) →
Task 8; Risks → covered by the guards in Task 1 and the probe in Task 5.

**Known limitation, stated rather than hidden.** `install.sh` cannot execute on
the development machine — it requires `loginctl`. Its `db` precondition is
therefore verified by `bash -n`, by review, and on the host in Task 8, not by an
automated test. The fail-closed property it enforces is independently covered by
layer 1, which *is* tested in CI. Extracting the installer's validation into a
unit-testable library was considered and rejected: it would touch the riskiest
file in the repo for a change the spec does not call for.

**Type consistency.** `pg-dump.sh` env names are identical in Tasks 4 (script),
2 (appdb-dump), and 4 (mattermost-postgres-dump rewire): `DB_DUMP_ALL`,
`DB_DUMP_PREFIX`, `DB_DUMP_HOUR`, `DB_DUMP_MINUTE`, `DB_DUMP_KEEP_DAYS`,
`DB_DUMP_DIR`, `DB_DUMP_ON_START`. Seed vars are identical in Tasks 3 (script),
2 (compose), 5 (installer checks), and 6 (`.env.example`): `APPDB_APP_USER`,
`APPDB_APP_PASSWORD`, `APPDB_DATABASES`, `APPDB_SUPERUSER`,
`APPDB_SUPERUSER_PASSWORD`. Service names `appdb` / `appdb-adminer` /
`appdb-dump` and network `appdb-net` are used identically in Tasks 1, 2, 5, 7, 8.
