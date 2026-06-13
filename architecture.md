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

Status: ✅ implemented, committed.

---

## Phase 3: Portainer CE (Container Management Dashboard)

### Goal
Web UI to manage the local Podman environment. Reachable via `https://portainer.localcloud.example` (prod, thru `cloudflared`) and `http://localhost:9000` (dev, for local testing).

### Domain Standardization
New `.env` variables, used across all future services so subdomains follow one pattern:
```
BASE_DOMAIN=localcloud.example
PORTAINER_SUBDOMAIN=portainer
```
- Expected external URL: `https://${PORTAINER_SUBDOMAIN}.${BASE_DOMAIN}` → `https://portainer.localcloud.example`.
- These vars aren't consumed by `docker-compose.yml` directly (Portainer itself doesn't need to know its public hostname for basic operation) — they exist as the **single source of truth for the Cloudflare Zero Trust setup**, done manually in the Cloudflare dashboard (not part of compose):
  1. Zero Trust → Networks → Tunnels → (existing tunnel from Phase 1) → Public Hostname → Add a public hostname.
  2. Subdomain: `${PORTAINER_SUBDOMAIN}` (`portainer`), Domain: `${BASE_DOMAIN}` (`localcloud.example`).
  3. Service: `HTTP`, URL: `portainer:9000` — container name + internal port, resolved via `homelab-net` since `cloudflared` is on the same network.
- Every future exposed service repeats this pattern: define `<SERVICE>_SUBDOMAIN` in `.env`, add a Public Hostname rule pointing `<service>:<port>` — `.env` becomes the running inventory of all subdomains in use.

### Image & Service Config
- `image: portainer/portainer-ce:latest`
- `restart: unless-stopped`
- `networks: [homelab-net]`
- `command: -H unix:///var/run/docker.sock` (Portainer's default; podman's socket is Docker-API compatible so no special flags needed beyond the socket mount itself).

### Ports: Dev Convenience vs Prod Zero-Ports
Requirement asks for both: local `9000:9000` for Mac testing, but no host port mapping in prod (cloudflared handles routing internally via container name).

**New pattern introduced here**: split into `docker-compose.yml` (shared, prod-safe — no `ports:` on portainer) + `docker-compose.override.yml` (dev-only, adds `9000:9000`). Both `docker-compose` and `podman-compose` auto-load `docker-compose.override.yml` if present, merging it over the base file — no extra flags needed.
- **Dev (macOS)**: keep `docker-compose.override.yml` in place (can stay tracked in git — it's not secret, just dev convenience). `podman-compose up` → Portainer reachable at `localhost:9000`.
- **Prod (Debian)**: either don't deploy `docker-compose.override.yml`, or delete/rename it on the server. `podman-compose up` then runs base file only → zero ports, identical to Phase 1/2 principle. Will note this explicitly in a future "prod deploy checklist."

### Socket Mount: Dev (macOS) vs Prod (Debian rootless Podman)

### Socket Mount: Dev (macOS) vs Prod (Debian rootless Podman)
Portainer needs the container engine socket mounted at `/var/run/docker.sock` inside its container (its built-in auto-detection looks there; podman's socket speaks the same API).

| Env | Host socket path | Notes |
|---|---|---|
| **Dev (macOS)** | `/var/folders/g4/sd497xns72n6vnpld82cp7j40000gn/T/podman/podman-machine-default-api.sock` | confirmed via `podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'` — this path is specific to this Mac's podman machine VM, but the podman machine's API service is already running by default, no extra setup |
| **Prod (Debian, rootless)** | `/run/user/1000/podman/podman.sock` | requires `systemctl --user enable --now podman.socket` on the server (one-time setup, documented but not automated by compose) |

Resolved via `.env`:
```
# Dev (macOS) — output of: podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'
PODMAN_SOCKET_PATH=/var/folders/g4/sd497xns72n6vnpld82cp7j40000gn/T/podman/podman-machine-default-api.sock
# Prod (Debian rootless) — uncomment/set on server's .env instead:
# PODMAN_SOCKET_PATH=/run/user/1000/podman/podman.sock
```
compose: `${PODMAN_SOCKET_PATH}:/var/run/docker.sock` — single line, identical compose file both environments, only `.env` differs (same pattern as `TUNNEL_TOKEN` / `BACKUP_DEST_PATH`).

### Persistent Data Volume
- Bind mount `./data/portainer:/data` (Portainer's internal DB — users, credentials, endpoint configs).
- **Deliberately a bind mount, not a named volume** — keeps it a plain host directory under a known path, consistent with the `./data/<service>` convention this project is standardizing on, and directly compatible with the backup sidecar's existing generic loop (see below).

### Backup Integration
**No changes to `backup.sh` itself required.** Phase 2's script already generically loops over every subdirectory under `/sources/` and rsyncs it to `/backup/<name>/`. The only change needed:

- Add to `backup` service's volumes in `docker-compose.yml`:
  ```yaml
  - ./data/portainer:/sources/portainer:ro
  ```
- On next 03:00 run, `backup.sh` automatically picks up `/sources/portainer/`, rsyncs with `-aAXH --numeric-ids --delete` to `/backup/portainer/` — same numeric-UID/ACL/xattr preservation guarantees as everything else.
- Restore: copy `portainer/` backup subdir back into `./data/portainer/`, `podman-compose up -d` — Portainer starts with identical users/credentials/endpoints, no re-setup.

This validates the Phase 2 design choice (generic `/sources/*` loop) — adding new backed-up services from here on is just a one-line volume addition, zero script edits.

### Socket Mount Security Note
Mounting the container socket gives Portainer full control over all containers on the host (start/stop/inspect/exec into any container). On rootless Podman this is scoped to the user's own containers (no host-root access), which is materially safer than the equivalent on Docker (where the daemon socket is root-owned). Worth flagging now — full secret/access-control hardening for Portainer's own login is a separate future concern, not blocking this phase.

### Docker ↔ Podman Compatibility Notes
1. **Socket path differs entirely between platforms** (Mac podman-machine VM temp path vs Linux rootless `/run/user/1000/...`) — handled via `.env`, see table above. On Docker Desktop (if ever used instead) it would be `/var/run/docker.sock` directly — same `.env` mechanism would cover that too.
2. **Socket mount + SELinux (Debian/Podman)**: similar to Phase 2's bind-mount note — may need `:z`/`:Z` suffix on the socket mount on enforcing-SELinux hosts. Flag as something to verify on first prod deploy.
3. **Podman socket service must be running** — on macOS it's part of the podman machine VM (always on once machine started); on Debian rootless it requires the one-time `systemctl --user enable --now podman.socket`. Will note this in a future "prod setup checklist" doc.

### Files to Change (pending approval)
- update `docker-compose.yml` — add `portainer` service (homelab-net, socket + `./data/portainer:/data` bind mounts, no ports) and add `./data/portainer:/sources/portainer:ro` to `backup` service volumes
- new `docker-compose.override.yml` — adds `9000:9000` port mapping to `portainer` for local dev/testing
- update `.env.example` — add `PODMAN_SOCKET_PATH` (dev value set, prod value commented), `BASE_DOMAIN`, `PORTAINER_SUBDOMAIN`

Status: ✅ implemented, committed.

---

## Phase 4: Hardware & Temperature Monitoring (Glances)

### Goal
Lightweight web dashboard for CPU/RAM/temperature on the 2013 prod host, reachable at `https://monitor.localcloud.example` via tunnel, `localhost:61208` in dev.

### Tool Choice: Glances (web server mode)
- **Glances over Netdata** for this hardware: Netdata's default config runs ~15-30+ collector plugins, a long-retention metrics DB, and a Go/C daemon that idles noticeably higher in RAM (~100MB+) — heavy for a 2013 laptop meant to also run cloudflared/Portainer/backup. Netdata *can* be stripped down, but that's extra config surface for marginal gain.
- **Glances** is a single Python process (`psutil`-based), built-in web server mode (`-w` flag), no database, no retention — just live stats served as a webpage/API. RAM footprint typically ~30-50MB, near-zero idle CPU. Exactly the "ultra-lightweight" fit.
- Image: `nicolargo/glances:latest` (official, maintained, includes `-full` variant if extra export plugins ever needed — not required here).
- Enabled via `GLANCES_OPT=-w` env var (image entrypoint passes this to the glances command → starts built-in web UI on port `61208`).

### Temperature Sensor Access (rootless Podman, Debian)
Temperature/fan/voltage data on Linux comes from `/sys/class/hwmon/*` (and sometimes `/sys/class/thermal/*`), populated by kernel sensor drivers (`coretemp`, etc.) and named via `lm-sensors`/`udev`.

Required mounts (read-only — monitoring never needs to write):
```yaml
volumes:
  - /sys:/sys:ro
  - /run/udev:/run/udev:ro
```
- `/sys:/sys:ro` — gives `psutil.sensors_temperatures()` access to `/sys/class/hwmon/hwmon*/temp*_input`, the actual readings.
- `/run/udev:/run/udev:ro` — lets `psutil`/`lm-sensors` resolve hwmon device names to human-readable labels (e.g. "Core 0" vs raw `hwmon2`) — without it, temps still read but labels are generic.
- **No `privileged: true`, no extra `cap_add` needed** — these are read-only sysfs paths, world-readable by default on most kernels for `coretemp`/`acpi` thermal zones.

**Host-side prerequisite (Debian prod, one-time, outside compose)**: kernel sensor modules must be loaded — `sensors-detect` (from `lm-sensors` package) + `modprobe coretemp` (or relevant chip driver). If modules aren't loaded, `/sys/class/hwmon` is empty/sparse regardless of container mounts. Will document as a step in the future "prod setup checklist," not a compose concern.

**Known caveat to verify on real prod hardware**: a few hwmon drivers restrict `temp*_input` to root-readable only. Rootless Podman containers run as root *inside* the user namespace but that root is mapped to an unprivileged host UID — if a specific sensor file is `0600 root:root` on the host, the container may see it but still get a permission error reading it. If this happens on the 2013 Debian box, the fallback is a `udev` rule to relax perms on that specific hwmon node (chip-specific, decided when we see real hardware) — flagging now, not blocking this spec.

### Domain Routing
New `.env` variable, same pattern as Phase 3:
```
MONITOR_SUBDOMAIN=monitor
```
- Expected external URL: `https://${MONITOR_SUBDOMAIN}.${BASE_DOMAIN}` → `https://monitor.localcloud.example`.
- Cloudflare Zero Trust → same tunnel → add Public Hostname: Subdomain `monitor`, Domain `localcloud.example`, Service `HTTP`, URL `glances:61208` (container name + Glances' web port, resolved via `homelab-net`).

### Service Config
- `image: nicolargo/glances:latest`
- `container_name: glances`
- `restart: unless-stopped`
- `environment: GLANCES_OPT=-w`
- `networks: [homelab-net]`
- no `ports:` in base file (zero-ports principle)
- `pid: host` — **not** requested by this spec; omitted to keep container fully namespace-isolated. Process-level stats will show container's own view rather than host processes; CPU/RAM/temp totals (the actual ask) are unaffected since those come from `/proc` and `/sys` which reflect host-wide stats regardless. Flagging as a deliberate scope limit — can revisit if per-process host visibility is wanted later.

### Config File & Backup Integration
- `./data/monitor/glances.conf` — optional custom config (e.g. temperature warning/critical thresholds). Bind mount:
  ```yaml
  - ./data/monitor:/glances/conf:ro
  ```
  and extend `GLANCES_OPT=-w -C /glances/conf/glances.conf` once the file exists (image looks for config at that path when `-C` passed).
- **Backup**: add to `backup` service volumes in `docker-compose.yml`:
  ```yaml
  - ./data/monitor:/sources/monitor:ro
  ```
  Same generic `/sources/*` loop from Phase 2 picks it up automatically — zero `backup.sh` changes, identical to Phase 3's pattern.

### Dev/Prod Port Mapping
- Base `docker-compose.yml`: no ports on `glances`.
- `docker-compose.override.yml`: add
  ```yaml
  glances:
    ports:
      - "61208:61208"
  ```
  → `http://localhost:61208` for Mac testing.

### Docker ↔ Podman Compatibility Notes
1. `/sys:/sys:ro` and `/run/udev:/run/udev:ro` mount identically on both platforms syntactically; actual sensor *availability* differs — macOS (Docker/Podman VM) has no real `coretemp` hwmon data (VM's `/sys` won't expose host Mac thermals), so **temperature panel will likely show empty/N/A in dev** — expected, not a bug. CPU/RAM stats work fine in dev for functional testing.
2. SELinux (Debian/Podman): as with prior phases, `/sys` and `/run/udev` read-only mounts may need `:ro,z` if enforcing — verify on first prod deploy.
3. `./data/monitor:/glances/conf:ro` and backup mount — same bind-mount conventions as Phase 3, no platform divergence.

### Files to Change (pending approval)
- update `docker-compose.yml` — add `glances` service (homelab-net, `/sys` + `/run/udev` ro mounts, `./data/monitor:/glances/conf:ro`, no ports) and add `./data/monitor:/sources/monitor:ro` to `backup` service volumes
- update `docker-compose.override.yml` — add `61208:61208` port mapping for `glances`
- update `.env.example` — add `MONITOR_SUBDOMAIN`

Status: ✅ implemented, committed.

---

## Phase 5: Gitea (Self-Hosted Git Server)

### Goal
Self-hosted git over HTTPS (via tunnel, `https://git.localcloud.example`) and SSH (direct, port-forwarded), backed by SQLite — no extra DB container.

### SQLite Choice & RAM Impact
- `GITEA__database__DB_TYPE=sqlite3` (single env var) — Gitea ships SQLite support built-in, DB is just a file (`/data/gitea/gitea.db`).
- Avoids a second container entirely: Postgres/MySQL each idle at roughly 50-150MB RAM plus their own restart/healthcheck/backup concerns. On a 2013 box already running cloudflared + Portainer + Glances + backup, that's meaningful headroom saved.
- SQLite's concurrency limits (single-writer) are a non-issue for a single-user/small-team homelab git server — this is the documented, supported Gitea config for exactly this use case.

### Domain Routing (HTTP)
New `.env` variable, same pattern as Phases 3/4:
```
GITEA_SUBDOMAIN=git
```
- Expected external URL: `https://${GITEA_SUBDOMAIN}.${BASE_DOMAIN}` → `https://git.localcloud.example`.
- Cloudflare Zero Trust → same tunnel → Public Hostname: Subdomain `git`, Domain `localcloud.example`, Service `HTTP`, URL `gitea:3000`.
- `ROOT_URL` left **unset/auto-detected** — Gitea derives it from request headers (`X-Forwarded-*`, which `cloudflared` sets), so the same container works correctly whether accessed via `https://git.localcloud.example` (prod) or `http://localhost:3000` (dev) without an env-specific override.

### SSH Access — the Zero-Ports Exception
HTTP(S) git operations route fine through the Cloudflare tunnel (it's just web traffic). **Raw `git@host:repo` SSH does not** — Cloudflare's standard tunnel is HTTP/TCP-app-aware via Zero Trust Access, but consuming SSH that way requires every client to install `cloudflared access ssh` config locally, which adds friction for a feature (`git push` over SSH) meant to be transparent.

**Decision for this phase**: accept one deviation from zero-open-ports — forward `2222:22` directly in the **base** `docker-compose.yml` (not the override), since this is needed in prod too, not just dev.
- `GITEA__server__SSH_PORT=2222` — tells Gitea to advertise port `2222` in clone URLs/instructions (container's internal sshd still listens on 22; this is just the externally-visible number).
- `GITEA__server__SSH_DOMAIN=${BASE_DOMAIN}` — clone URLs show `git@localcloud.example:2222/...`. Requires, on prod: a DNS A record for `localcloud.example` (or reuse existing) pointing at the home public IP, plus router port-forward `2222 → 2222` on the Debian host.
- Flagging as a tracked exception, not silently introduced — `.env`/architecture doc both note it. HTTPS-based pushes remain available as the zero-port alternative if port-forwarding is ever undesirable.

### Volume & Backup Integration
- `./data/gitea:/data` — single bind mount covers everything: repos, SQLite DB (`gitea.db`), `app.ini` config, avatars, LFS objects, etc.
- Official `gitea/gitea` image runs as uid `1000` (`git` user) by default — aligns with Phase 2's `--numeric-ids` rsync design; restore-to-new-host preserves ownership without manual `chown`.
- Backup: append to `backup` service volumes in `docker-compose.yml`:
  ```yaml
  - ./data/gitea:/sources/gitea:ro
  ```
  Picked up automatically by the existing generic `/sources/*` loop — zero `backup.sh` changes, same as Phases 3/4.

### Ports Summary
- Base `docker-compose.yml`: **no** `3000` mapping (HTTP goes through tunnel); **yes** `2222:22` (SSH exception, documented above).
- `docker-compose.override.yml`: add `3000:3000` for local HTTP testing on macOS (`http://localhost:3000`).

### Docker ↔ Podman Compatibility Notes
1. Bind mount `./data/gitea:/data` — same bind-mount conventions as Phases 3/4; SELinux `:Z` flag to verify on first prod deploy (consistent open item across all bind mounts so far).
2. `2222:22` port mapping — rootless Podman can bind host ports ≥1024 without extra config (this is why `2222` was chosen over `22`); binding `22` directly would need `net.ipv4.ip_unprivileged_port_start` tuning on the Debian host. `2222` avoids that entirely.
3. uid `1000` inside container — under rootless Podman this maps to the *running user's* uid via user-namespace remapping (not literally host uid 1000). `--numeric-ids` rsync still works because it's preserving container-side numeric IDs, which is what matters for the container's own permission checks on restore — consistent regardless of which host uid the container's namespace maps to.

### Files to Change (pending approval)
- update `docker-compose.yml` — add `gitea` service (`image: gitea/gitea:latest`, `GITEA__database__DB_TYPE=sqlite3`, `GITEA__server__SSH_PORT=2222`, `GITEA__server__SSH_DOMAIN=${BASE_DOMAIN}`, `./data/gitea:/data`, `2222:22` port, homelab-net) and append `./data/gitea:/sources/gitea:ro` to `backup` service volumes
- update `docker-compose.override.yml` — add `3000:3000` for `gitea`
- update `.env.example` — add `GITEA_SUBDOMAIN`

Awaiting approval before implementation.
