# Home Server Architecture

## Phase 1: Cloudflare Tunnel Gateway

### Goal
Single secure entrypoint via `cloudflared`. Zero inbound ports on router/firewall. All future services reach internet only thru this tunnel.

### Directory Structure
```
homelab/
├── architecture.md
├── docker-compose.yml
├── .env              # secrets, gitignored
├── .env.example       # template, committed
└── .gitignore
```

No `cloudflared/config.yml` needed — token-based tunnel mode handles routing config remotely via Cloudflare Zero Trust dashboard. Keeps setup minimal, fewer volume mounts (good for Podman rootless compat).

### Service: `cloudflared`

| Setting | Value | Notes |
|---|---|---|
| image | `cloudflare/cloudflared:latest` | pin to digest later for repro builds, optional now |
| command | `tunnel --no-autoupdate run --token $TUNNEL_TOKEN` | `--no-autoupdate`: avoid self-update on 2013 hw, control updates manually via image pulls |
| restart | `unless-stopped` | Docker-native field, podman-compose honors it too |
| network | `homelab-net` (bridge, external/dedicated) | future services join same network → cloudflared can proxy to them by container name (e.g. `http://jellyfin:8096`) |
| ports | none | core constraint — tunnel is outbound-only, no `ports:` mapping |
| env_file | `.env` | injects `TUNNEL_TOKEN` |

### `.env` Injection
- `.env` holds `TUNNEL_TOKEN=<your-tunnel-token>` — gitignored.
- `.env.example` committed with placeholder, documents required var.
- compose references via `env_file: - .env` (whole-file load, no need to enumerate each var) and command interpolates `$TUNNEL_TOKEN`.

### Network
- Define top-level network `homelab-net` (driver: bridge) in compose.
- Dedicated network (not default) so future service containers explicitly opt in by listing it, avoiding accidental cross-talk with other podman/docker stacks on host.

### Docker ↔ Podman Compatibility Notes
1. **No port mappings needed** — sidesteps biggest rootless-Podman pain point (low ports <1024 need extra config). Zero-port design avoids this entirely.
2. **`restart: unless-stopped`** — works with `podman-compose`, but Podman has no persistent background daemon like Docker Desktop. For prod boot-persistence, will eventually want `podman generate systemd` + enable as user/system systemd unit (separate task, not blocking Phase 1).
3. **Bridge network creation** — both `docker-compose` and `podman-compose` create the bridge network fine from compose file; naming/DNS resolution between containers on same network works identically (container name = hostname) in both.
4. **`env_file`** — supported identically by both.
5. **Volumes** — none required this phase, sidesteps SELinux `:Z`/`:z` label differences relevant on Debian Podman.

### Files to Create (pending approval)
- `docker-compose.yml` — cloudflared service + homelab-net network
- `.env.example`
- `.gitignore` (exclude `.env`)

Status: ✅ implemented, committed.

---

## Phase 2: Autonomous USB Backup / Disaster Recovery Sidecar

### Goal
Lightweight cron-driven container that `rsync`s service data volumes to a USB (prod) or local mock dir (dev) daily at 03:00 Europe/Istanbul time. Backup must be byte-for-byte restorable: copy files back, `podman-compose up`, services resume with zero permission/ownership issues.

### Directory Structure (additions)
```
homelab/
├── architecture.md
├── docker-compose.yml
├── .env / .env.example
├── .gitignore
└── backup/
    ├── Dockerfile
    ├── crontab           # cron schedule definition
    └── backup.sh          # rsync script run by cron
```

`alpine:latest` base image needs `rsync` + `tzdata` added — not present by default — so a tiny custom `Dockerfile` is required (still ~10MB+base, far lighter than any full-distro image). This is the only way to satisfy both "alpine only" and "rsync + correct TZ cron" constraints.

### Image Build
`backup/Dockerfile`:
- `FROM alpine:latest`
- `RUN apk add --no-cache rsync tzdata`
- `ENV TZ=Europe/Istanbul`
- copy `crontab` → `/etc/crontabs/root` (busybox crond's per-user table, picked up automatically)
- copy `backup.sh` → `/usr/local/bin/backup.sh`, `chmod +x`
- `CMD ["crond", "-f", "-l", "2"]` — foreground cron daemon, log level 2 (so `podman/docker logs` shows job runs)

### Timezone Handling
- `tzdata` package provides `/usr/share/zoneinfo`.
- `ENV TZ=Europe/Istanbul` baked into image — busybox `crond` and `date` both honor `TZ`, so 03:00 fires in Istanbul local time regardless of host clock/timezone (important since Mac dev host and Debian prod host may differ).

### Cron Job Injection
- `backup/crontab` contains one line:
  ```
  0 3 * * * /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
  ```
- Baked into image at `/etc/crontabs/root` at build time — no runtime volume mount needed for the schedule itself, keeping the container self-contained.

### `backup.sh` — rsync Logic & Disaster-Recovery Guarantees
```sh
#!/bin/sh
rsync -aAXH --numeric-ids --delete \
  /sources/<service-a>/ /backup/<service-a>/ \
  /sources/<service-b>/ /backup/<service-b>/
```
(actual sources listed once Phase 3+ volumes exist; placeholder for now)

Flag rationale (all required for "drop-in restore, zero permission errors"):
- `-a` (archive): recursive + preserves perms, timestamps, symlinks, groups, owners, devices.
- `-A`: preserve ACLs.
- `-X`: preserve extended attributes (xattrs) — some apps (e.g. databases) rely on these.
- `-H`: preserve hard links — avoids duplicating/breaking linked files.
- `--numeric-ids`: preserve UID/GID as raw numbers, not name-mapped. **Critical for cross-machine restore** — a new Debian box may not have matching `/etc/passwd` entries, but containers run as fixed numeric UIDs, so numeric preservation keeps container-side permissions correct on restore.
- `--delete`: keeps backup in sync if source files are removed — backup mirrors current state exactly (true "drop-in replacement", not an ever-growing archive). Flag this as a deliberate choice: if accidental deletion in source should be recoverable, we'd need versioned/snapshot backups instead — out of scope for this phase, can revisit later.

### Volume Mapping & Dev/Prod Path Differences
- **Source volumes (`:ro`)**: future service data dirs mounted read-only into `/sources/<service>/` inside the backup container — e.g. `./data/gitea:/sources/gitea:ro` once Gitea exists. Read-only enforces sidecar can never mutate live data.
- **Destination volume**: single bind mount to `/backup` inside container, rsync writes per-service subdirs underneath.
  - **Dev (macOS)**: `./mock-usb:/backup`
  - **Prod (Debian)**: `/mnt/usb-disk:/backup`
- Path difference resolved via `.env`:
  ```
  BACKUP_DEST_PATH=./mock-usb        # dev
  # BACKUP_DEST_PATH=/mnt/usb-disk   # prod — uncomment/set on server's .env
  ```
  compose references `${BACKUP_DEST_PATH}:/backup` — single compose file works on both, only `.env` differs per host. Same pattern already used for `TUNNEL_TOKEN`.

### Restore Procedure (documented in spec for future reference)
1. Plug USB into new host, mount at `/mnt/usb-disk` (or copy contents to a local path).
2. Copy/rsync backup subdirs back into the corresponding `./data/<service>/` volume dirs (numeric UID/GID preserved → no `chown` needed).
3. `podman-compose up -d` — services see identical data, permissions, timestamps as before crash.

### Docker ↔ Podman Compatibility Notes
1. Custom image build via `Dockerfile` — both `docker-compose` and `podman-compose` support `build:` context identically.
2. Read-only bind mounts (`:ro`) — identical syntax/behavior both platforms.
3. **SELinux note (Debian/Podman only)**: if the Debian host has SELinux enforcing, bind mounts may need `:ro,Z` or `:ro,z` suffix for the container to read them. macOS has no SELinux — flagging this as a likely per-`.env`/per-host compose difference once we're on real prod volumes. Will revisit when Phase 3 introduces actual service data volumes.
4. `crond -f` foreground mode — required so the container's main process doesn't exit (both Docker and Podman kill the container if PID 1 exits); works identically on both.

### Files to Create (pending approval)
- `backup/Dockerfile`
- `backup/crontab`
- `backup/backup.sh`
- update `docker-compose.yml` — add `backup` service (build from `./backup`, source volumes placeholder/commented until real services exist, `${BACKUP_DEST_PATH}:/backup`)
- update `.env.example` — add `BACKUP_DEST_PATH`

Awaiting approval before implementation.
