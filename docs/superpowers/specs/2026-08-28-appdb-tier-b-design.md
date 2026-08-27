# Application Database (Tier B) — Design

Date: 2026-08-28
Status: approved, not yet implemented
Implements: `docs/tailscale.md` Phase V3 — First Tier B Service (PostgreSQL)

## Problem

LocalCloud Stack has a written three-tier exposure model, but no service
occupies Tier B (Private). Tailscale is installed and validated by the
installer, yet nothing binds to `tailscale0`. The tier exists on paper only.

Separately, the operator needs a general-purpose relational database for
backend applications they are writing. Those applications will run both on
this host (as future compose services) and remotely (laptop, another server).
The database must be reachable over Tailscale, must never be published through
Cloudflare Tunnel or onto the LAN, must not be recreated from scratch on every
install, and must not hand out a different administrative password each time.

This design adds that database as the stack's first Tier B service.

## Non-Goals

- Reusing or modifying `mattermost-postgres`. It stays Tier C, stays on
  `db-net`, stays gated behind the `chat` profile, and keeps its own image pin.
- Declarative configuration sync. Seed values apply to an empty data directory
  only; after that the database is the source of truth.
- Moving Gitea SSH or host SSH to Tier B. Those remain separate decisions
  (`docs/tailscale.md` Phase V4).
- Connection pooling, replication, or PITR/WAL archiving.

## Constraints Inherited From The Repo

These are load-bearing and were each learned from a production failure. The
design must not regress any of them.

| Constraint | Why |
|---|---|
| No `condition: service_healthy` | Podman runs healthchecks as systemd user timers; a missing user DBus session leaves health `starting` forever and blocks `up -d` until the unit's start timeout. |
| Persistent data only under `./data/<service>` | Backup and restore assume this shape. |
| `restart: unless-stopped` | Containers must return after a power cut. |
| Optional/heavy services behind a profile | `CONTRIBUTING.md`. |
| Image refs overridable from `.env` | Reproducible upgrades. |
| No bare `"<port>:<port>"` publishes | CI-enforced; a bare publish binds all interfaces. |
| Fail closed on missing configuration | `SECURITY.md`; prefer an explicit error over a guess. |

## Architecture

### Services

A new profile, `db`, off by default, adds three services.

| Service | Image | Networks | Published port |
|---|---|---|---|
| `appdb` | `${APPDB_IMAGE:-docker.io/postgres:17-alpine}` | `appdb-net` | `${TAILSCALE_IP}:${APPDB_PORT:-5432}` → 5432 |
| `appdb-adminer` | `${ADMINER_IMAGE:-docker.io/library/adminer:latest}` | `appdb-net` | `${TAILSCALE_IP}:${ADMINER_PORT:-8081}` → 8080 |
| `appdb-dump` | `${APPDB_IMAGE}` | `appdb-net` | none |

`APPDB_IMAGE` is deliberately a separate variable from `POSTGRES_IMAGE`. A
PostgreSQL major-version bump requires a dump/restore cycle, so a change driven
by Mattermost must not silently move the application database.

### Network

A new bridge, `appdb-net`, with `internal: true`.

`db-net` is not reused: the operator's requirement is that the application
database be fully separate from Mattermost, and network reachability is part of
"separate". Future backend containers join `appdb-net` and reach the database at
`appdb:5432`, never through the published host port.

None of the three services join `edge-net`. This matters more than the
Cloudflare dashboard configuration: `cloudflared` can only reach services on
`edge-net`, so a public hostname created by mistake still cannot route to the
database. The "never through Cloudflare" requirement is enforced by topology,
not by remembering not to click something.

`internal: true` removes egress. None of the three services need it.

**Verified 2026-08-28** (Podman 5.8.3, rootless, netavark). The repo had no
precedent for publishing a host port from a container on an `internal: true`
network — `mattermost-postgres` is internal but publishes nothing — so this was
measured rather than assumed. A probe service on an `internal: true` bridge
published `127.0.0.1:15432` and answered `HTTP 200` from the host, while an
outbound `connect()` to `1.1.1.1:443` from inside that container failed with
`OSError`. Both properties hold at once: the host reaches in, the container
cannot reach out. No fallback needed.

### Fail-Closed Exposure Guard

`"${TAILSCALE_IP}:5432:5432"` with an empty `TAILSCALE_IP` renders as
`":5432:5432"`, which Podman reads as *bind every interface*. That would put the
database on the LAN — the exact outcome the tier forbids. Three independent
layers prevent it.

**Layer 1 — compose engine.** The port mapping uses the required-variable form:

```yaml
ports:
  - "${TAILSCALE_IP:?TAILSCALE_IP is empty. The db profile is Tailscale-only; set TAILSCALE_ENABLED=true and run ./install.sh}:${APPDB_PORT:-5432}:5432"
```

Any `podman-compose` invocation — including one typed by hand, bypassing the
installer — fails with that message rather than binding wide.

**Verified 2026-08-28** on podman-compose 1.6.0: an empty `TAILSCALE_IP` exits
`1` and prints the message; a set one renders `100.64.0.1:5432:5432`.

The version floor for this substitution form is not known, however. The repo
already requires podman-compose >= 1.1.0 for `--profile`, and older builds may
substitute empty instead of failing — which would silently disarm layer 1 on
exactly the Ubuntu-packaged versions the installer already works around.
`install.sh` therefore probes the capability the same way
`require_compose_profile_support` does, rather than parsing a version string.

**Layer 2 — installer.** When `LOCALCLOUD_PROFILES` contains `db`,
`install.sh` requires `TAILSCALE_ENABLED=true` and fails before any container
starts:

```
ERROR: LOCALCLOUD_PROFILES includes 'db', but TAILSCALE_ENABLED is not 'true'.
The application database is a Private (Tier B) service: it is reachable only
over Tailscale and must never be published to the LAN or through Cloudflare.
Complete deployment.md section 13 (Private Tier), set TAILSCALE_ENABLED=true,
then run ./install.sh again.
```

The same block requires `APPDB_SUPERUSER_PASSWORD`, `APPDB_APP_USER`,
`APPDB_APP_PASSWORD`, and `APPDB_DATABASES` through the existing
`require_env_value`, which already rejects `change-me` placeholders.

**Layer 3 — CI.** Two additions:

1. A bind allowlist: every published port in `docker-compose.yml` and
   `compose.dev.yml` must have a host part of `127.0.0.1`, `${LAN_IP`, or
   `${TAILSCALE_IP`. Anything else fails the build.
2. A negative test: `--profile db config` with an empty `TAILSCALE_IP` must
   **fail**. The fail-closed behavior itself becomes a tested property rather
   than an assumed one.

## Seed Model

A new repo directory, `db/initdb/`, mounted read-only at
`/docker-entrypoint-initdb.d`.

The PostgreSQL image contract is that these scripts run **only when `PGDATA` is
empty**. That contract is what satisfies both halves of the operator's
requirement:

- Restoring from backup repopulates `./data/appdb/postgres`, so the directory is
  not empty, so the seed does not run and cannot overwrite restored data.
- A genuinely fresh machine gets its roles and databases created automatically,
  with no manual `CREATE DATABASE`.

New `.env` keys:

```sh
APPDB_SUPERUSER_PASSWORD=      # openssl rand -hex 32
APPDB_APP_USER=appuser
APPDB_APP_PASSWORD=            # openssl rand -hex 32
APPDB_DATABASES=app1,app2      # comma-separated; each owned by APPDB_APP_USER
APPDB_PORT=5432
ADMINER_PORT=8081
```

`APPDB_APP_USER` and every entry in `APPDB_DATABASES` are validated against
`^[a-z_][a-z0-9_]*$` before use. They become SQL identifiers, which cannot be
parameterized the way values can, so the safe move is to reject anything
unusual rather than attempt to quote it. A rejected name fails the seed loudly.

`appdb-adminer` sets `ADMINER_DEFAULT_SERVER=appdb` so the login form arrives
pre-pointed at the database; Adminer has no accounts of its own, so the
PostgreSQL credentials are the only authentication.

Hex, not base64: `+`, `/`, and `=` break a `postgres://` connection string. This
mirrors the existing `MATTERMOST_DB_PASSWORD` note.

Password stability follows from `.env` being persistent and owner-readable only.
Nothing is randomly generated at install time, so the credentials are identical
across reinstalls, restarts, and restores.

The seed script passes secrets through `psql -v pw="$APPDB_APP_PASSWORD"` and
references them as `:'pw'`, letting psql handle quoting. Passwords are never
interpolated into SQL text directly.

**Known and documented limitation.** Changing `APPDB_APP_PASSWORD` in `.env`
after the first boot does not change it in the database. `deployment.md` states
this plainly and gives the `ALTER ROLE ... PASSWORD` rotation command. Making
`.env` authoritative on every start was considered and rejected as YAGNI — the
approved requirement was "automatic on a fresh machine", not "declarative".

## Backup Model

### File-level

One line added to the existing `backup` sidecar:

```yaml
- ./data/appdb:/sources/appdb:ro
```

Encryption, retention, the mount marker guard, and the schedule are unchanged.
Both the raw `PGDATA` and the logical dumps land in the same restic snapshot
because both live under `./data/appdb`.

`backup/backup.sh` gains `--exclude "/sources/appdb/db-dumps/*.tmp"`, matching
the existing Mattermost exclude.

### Logical dumps

`appdb-dump` follows the `mattermost-postgres-dump` pattern, with one
difference: Mattermost has a single known database, while this server hosts an
unknown number of application databases. Each run therefore produces:

1. `pg_dumpall --globals-only` → `globals-<ts>.sql`. Without roles and their
   passwords, a restored database is unreachable by the applications.
2. For every database where `datallowconn AND NOT datistemplate`:
   `pg_dump --format=custom` → `<db>-<ts>.dump`, plus a `<db>-latest.dump` copy.
3. Pruning by age, same mechanism as the Mattermost sidecar.

Schedule: `02:30`. Mattermost dumps at `02:45`, restic snapshots at `03:00`;
the three do not overlap.

### Shared dump script

`backup/mattermost-db-dump.sh` is generalized to `backup/pg-dump.sh` and used by
both dump sidecars. Its environment contract becomes generic
(`DB_DUMP_HOUR`, `DB_DUMP_MINUTE`, `DB_DUMP_KEEP_DAYS`, `DB_DUMP_PREFIX`,
`DB_DUMP_ALL`), and `docker-compose.yml` maps each service's values onto it.

User-facing `.env` keys do not change: `MATTERMOST_DB_DUMP_HOUR`,
`MATTERMOST_DB_DUMP_MINUTE`, and `MATTERMOST_DB_DUMP_KEEP_DAYS` keep their names
and are mapped to the generic ones inside compose. Existing installs see no
breakage.

`DB_DUMP_ALL=false` reproduces today's single-database Mattermost behavior
exactly — one `pg_dump` of `PGDATABASE` written as `${DB_DUMP_PREFIX}-<ts>.dump`
plus `${DB_DUMP_PREFIX}-latest.dump`, where `DB_DUMP_PREFIX=mattermost`
reproduces today's filenames byte for byte. `DB_DUMP_ALL=true` ignores
`DB_DUMP_PREFIX` and names each file after its own database.

### Restore

`restore.sh` needs one change: `db` joins the valid profile list in
`normalize_profiles`. Everything else is already generic over `./data/*`.

`deployment.md` documents two recovery paths:

- **Raw directory restore** — the normal path, via `./restore.sh`.
- **Logical restore** — when the raw data directory is damaged: load
  `globals-*.sql` first, then `pg_restore` each `<db>-latest.dump` into a clean
  `appdb` container.

The runbook states plainly that the raw `PGDATA` is copied file-level while
PostgreSQL may be writing, so it carries a torn-copy risk, and that the logical
dumps are the trustworthy path. This is already true of Mattermost and is not
newly introduced here.

## Installer Changes

`install.sh`:

1. `normalize_profiles` accepts `db`.
2. `db` requires `TAILSCALE_ENABLED=true` (message above).
3. `db` requires `APPDB_SUPERUSER_PASSWORD`, `APPDB_APP_USER`,
   `APPDB_APP_PASSWORD`, `APPDB_DATABASES`.
4. `mkdir -p ./data/appdb/{postgres,db-dumps}`.
5. The pre-start cleanup line gains `--profile db` so a disabled `db` profile
   does not leave containers running.

No `podman unshare chown` entry is added. The PostgreSQL entrypoint starts as
container-root and chowns `PGDATA` itself, which is why `install.sh` has no such
line for `./data/mattermost/postgres` either. The dump sidecar overrides the
command and therefore also runs as container-root, so the host-owned
`db-dumps` directory is writable. The existing
`for d in ./data/*/; do chmod go-rwx "$d" || true; done` loop already tolerates
subuid-owned directories.

`restore.sh`: `db` joins `normalize_profiles`.

## Documentation Changes

| File | Change |
|---|---|
| `.env.example` | `APPDB_*`, `ADMINER_PORT`, `APPDB_IMAGE`, `ADMINER_IMAGE`, with the Tailscale prerequisite stated |
| `README.md` | `db` row in the profile table; service table; Requirements notes Tailscale as a prerequisite for `db`; Security Model reflects that Tier B is now populated |
| `architecture.md` | Network Model gains `appdb-net`; Exposure Model moves PostgreSQL from planned to actual; Data Model gains `./data/appdb`; Backup Model gains the globals + per-database step; Optional Services gains `db` |
| `SECURITY.md` | Tier B rows become real rather than planned; `APPDB_*` in Secrets; the new bind allowlist under CI Enforcement; ufw guidance |
| `deployment.md` | New section 14, *Application Database*: enabling, remote connection (psql and GUI client DSNs over the tailnet), Adminer, seed semantics, password rotation, both restore paths, verification checklist. Sections 4, 8, and 13 updated |
| `docs/tailscale.md` | Phase V3 marked implemented, pointing at deployment section 14 |
| `CHANGELOG.md` | Added / Changed / Security entries |
| `CONTRIBUTING.md` | `--profile db` in the checklist command |
| `.github/workflows/ci.yml` | Profile list, bind allowlist, fail-closed negative test |

Incidental fix in the same change: `docs/tailscale.md` links to
"deployment.md section 11" for the Private Tier in two places, but that section
is 13 — section 11 is *Recovering A Wedged Stack*. Dead anchor, corrected.

## Testing

The repo has no runtime test harness; CI validates syntax and compose
configuration. Verification is therefore split between CI and a documented
manual pass.

Automated (CI):

- `bash -n` / `sh -n` on the changed scripts, including the new seed script.
- `docker compose --profile db config` succeeds with `TAILSCALE_IP` set.
- `docker compose --profile db config` **fails** with `TAILSCALE_IP` empty.
- Bind allowlist across both compose files.
- Existing checks unchanged.

Manual, on the target host, recorded in `deployment.md` section 14:

- `ss -tlnp | grep 5432` shows the `100.x` tailscale address and never `0.0.0.0`.
- `psql` from an enrolled remote device connects; from a LAN host that is not on
  the tailnet, it does not.
- A fresh `./data/appdb` produces the seeded roles and databases.
- A populated `./data/appdb` does not re-run the seed.
- `podman exec appdb-dump /usr/local/bin/pg-dump.sh once` writes `globals-*.sql`
  and one dump per database.
- Mattermost's dump sidecar still behaves identically after the script
  generalization.

## Risks

| Risk | Handling |
|---|---|
| Published port from an `internal: true` network may not work rootless | Resolved: verified working on Podman 5.8.3 rootless/netavark, with egress still blocked |
| Older podman-compose may ignore `${VAR:?}` and disarm layer 1 | `install.sh` probes the capability, in the idiom of `require_compose_profile_support` |
| Generalizing the dump script could regress Mattermost backups | `.env` keys preserved; `DB_DUMP_ALL=false` path is behavior-identical; manual verification listed above |
| Operator enables `db` without Tailscale | Three independent fail-closed layers |
| Raw `PGDATA` torn copy | Logical dumps are the documented recovery path |
| Postgres 17 differs from the Mattermost 15 pin | Separate image variable; independent upgrade path |
