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

Status: ✅ implemented, committed.

---

## Phase 6: n8n (Workflow Automation / Agentic Orchestration)

### Goal
Automation engine for webhooks, git-event hooks, AI-agent orchestration — reachable at `https://n8n.localcloud.example` (prod, via tunnel) and `localhost:5678` (dev).

### Resource Footprint & SQLite
- `n8nio/n8n:latest` — default DB is SQLite (file under `~/.n8n/database.sqlite`), no `DB_TYPE` env needed; only set it if we ever *wanted* Postgres, which we don't.
- Single Node.js process, idles roughly in the 150-250MB range — comparable to Gitea, no second DB container. Same rationale as Phase 5: every avoided sidecar container matters on 2013 hardware running 5 services already.
- SQLite is fine for n8n's typical homelab load (occasional webhook triggers, scheduled workflows) — single-writer limits aren't a practical constraint here.

### `WEBHOOK_URL` — Why It's Required
Unlike Gitea (which auto-detects its URL from proxy headers), n8n **bakes the webhook base URL into every workflow's webhook-node URL at creation/display time** — if unset or wrong, copy-pasted webhook URLs (e.g. for GitHub/Gitea webhook configs) would show `http://localhost:5678/webhook/...`, useless to external callers.

New `.env` variable, same pattern as Phases 3-5:
```
N8N_SUBDOMAIN=n8n
```
- `WEBHOOK_URL=https://${N8N_SUBDOMAIN}.${BASE_DOMAIN}` passed as container env → resolves to `https://n8n.localcloud.example`.
- **Deliberate choice: same value in dev and prod** — unlike the gitea `ROOT_URL` (left auto-detect), n8n needs *one* consistent value so webhook URLs displayed in the UI are always the real, externally-callable ones (via the tunnel), even when the n8n instance generating them happens to be running on the dev Mac. Editing a workflow locally and copying its webhook URL into e.g. a Gitea webhook config "just works" without a manual find/replace. No per-env override needed in `docker-compose.override.yml` for this var.
- Cloudflare Zero Trust → same tunnel → Public Hostname: Subdomain `n8n`, Domain `localcloud.example`, Service `HTTP`, URL `n8n:5678`.

### Volume, Permissions & Backup Integration
- `./data/n8n:/home/node/.n8n` — persists workflows, credentials (encrypted), execution history, and the SQLite DB.
- `n8nio/n8n` image runs as **non-root `node` user (uid 1000)** from the start (no root-then-drop-privileges step like some images) — it cannot `chown` a freshly-created bind mount itself. **First-run gotcha**: if `./data/n8n` doesn't exist yet, the container engine auto-creates it (commonly root-owned), and n8n's uid-1000 process gets `EACCES` on startup.
  - **Mitigation**: create `./data/n8n` on the host *before* first `up` (`mkdir -p ./data/n8n`) — both platforms create plain directories identically, sidesteps the auto-create-as-root issue entirely. Will note as a one-line step in the implementation/deploy notes.
- Once correctly owned by uid 1000 (or its rootless-Podman-mapped equivalent), this aligns directly with Phase 2's `--numeric-ids` rsync — same guarantee as Gitea: restore-to-new-host preserves ownership, n8n starts with identical workflows/credentials, no `chown` needed.
- Backup: append to `backup` service volumes in `docker-compose.yml`:
  ```yaml
  - ./data/n8n:/sources/n8n:ro
  ```
  Picked up automatically by the existing generic `/sources/*` loop — zero `backup.sh` changes, same as Phases 3-5.

### Ports Summary
- Base `docker-compose.yml`: no ports (internal `n8n:5678` via `homelab-net`, tunnel handles external).
- `docker-compose.override.yml`: add `5678:5678` for local dev (`http://localhost:5678`).

### Docker ↔ Podman Compatibility Notes
1. Bind mount `./data/n8n:/home/node/.n8n` — same conventions/SELinux `:Z` open item as prior phases.
2. Pre-creating `./data/n8n` directory (permissions mitigation above) is identical on macOS and Debian — plain `mkdir -p`, no platform divergence.
3. Encrypted credentials in n8n's SQLite DB are encrypted with a key n8n auto-generates and stores in `./data/n8n/config` on first run — since the whole `./data/n8n` dir is backed up together, the key and the encrypted data travel together, so restore decrypts correctly. (If we ever pin `N8N_ENCRYPTION_KEY` via `.env` instead of letting it auto-generate, that'd be a future hardening step — not needed now since it's bundled in the same backup.)

### Files to Change (pending approval)
- update `docker-compose.yml` — add `n8n` service (`image: n8nio/n8n:latest`, `WEBHOOK_URL=https://${N8N_SUBDOMAIN}.${BASE_DOMAIN}`, `./data/n8n:/home/node/.n8n`, no ports, homelab-net) and append `./data/n8n:/sources/n8n:ro` to `backup` service volumes
- update `docker-compose.override.yml` — add `5678:5678` for `n8n`
- update `.env.example` — add `N8N_SUBDOMAIN`

Status: ✅ implemented, committed.

---

## Phase 7: AdGuard Home (Network-Wide DNS Ad-Blocking)

### Goal
Network-wide DNS ad/tracker blocking for every LAN device, served from the prod host at a fixed address (`192.168.1.10`). **LAN-only** — no Cloudflare tunnel exposure, no subdomain. Web UI reachable at `http://192.168.1.10:3001` (prod) / `http://localhost:3001` (dev).

### Host-Side Prerequisites (Debian Prod)
These three items are **host OS configuration, not compose** — same category as Phase 4's `lm-sensors` step. All go into `deployment.md`, not `docker-compose.yml`.

#### 1. Static IP via netplan
DHCP reservations are modem-dependent and can drift; a netplan static config is independent of the router and guarantees AdGuard (and every client pointed at it) always finds the host at `192.168.1.10`.

`/etc/netplan/01-netcfg.yaml`:
```yaml
network:
  version: 2
  ethernets:
    <iface>:
      dhcp4: no
      addresses:
        - 192.168.1.10/24
      routes:
        - to: default
          via: <gateway-ip>
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```
Apply: `sudo netplan apply`. Also configure the modem's DHCP server to **reserve/exclude `192.168.1.10`** from its lease pool, so no other client can be handed this address — belt-and-suspenders alongside the static config.

#### 2. Unprivileged port 53 (rootless Podman)
Port `53` (DNS, TCP+UDP) is `<1024` — rootless Podman refuses to bind it by default.

`/etc/sysctl.d/99-unprivileged-port.conf`:
```
net.ipv4.ip_unprivileged_port_start=53
```
Apply: `sudo sysctl --system` (or reboot). One-time, persists across reboots via the sysctl.d file.

#### 3. Disable `systemd-resolved`'s stub listener
Ubuntu's `systemd-resolved` binds `127.0.0.53:53` by default (stub resolver) — this doesn't conflict with AdGuard binding `0.0.0.0:53`/`192.168.1.10:53` directly, but **does** prevent the host itself from later using AdGuard as its own resolver, and can cause confusing double-resolution behavior. Disable it:

`/etc/systemd/resolved.conf`:
```ini
[Resolve]
DNSStubListener=no
```
Then:
```sh
sudo systemctl restart systemd-resolved
# point host's own DNS at AdGuard once it's running:
sudo rm /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
```

### Image & Service Config
- `image: adguard/adguardhome:latest`
- `container_name: adguard`
- `restart: unless-stopped`
- `networks: [homelab-net]`
- Port 53 (DNS) **must be in base `docker-compose.yml`**, not just override — DNS has to work in prod:
  ```yaml
  ports:
    - "192.168.1.10:53:53/tcp"
    - "192.168.1.10:53:53/udp"
    - "3001:80"
  ```
  **DNS port is bound to the host LAN IP, not `0.0.0.0`** — see "DNS Port Binding: Why Not `53:53`" below. `192.168.1.10` must stay static (Phase 7 netplan config above) or AdGuard fails to start if the host's IP changes.
- Two bind mounts:
  ```yaml
  - ./data/adguard/conf:/opt/adguardhome/conf
  - ./data/adguard/work:/opt/adguardhome/work
  ```

### DNS Port Binding: Why Not `53:53`
Podman's embedded DNS (`aardvark-dns`) resolves container names (e.g. `portainer`, `gitea`) for every container on `homelab-net`, and listens on the bridge network's gateway address (`10.89.0.1:53`). `cloudflared` depends on this — its Cloudflare Tunnel config uses container-name origins like `http://portainer:9000`, resolved via `10.89.0.1`.

`"53:53"` (no host IP) binds to **all interfaces**, including `10.89.0.1` — AdGuard then captures container-name lookups too. AdGuard doesn't know container names, returns NXDOMAIN, and `cloudflared` can't resolve any origin → every public hostname returns **502 Bad Gateway**.

Binding to `192.168.1.10:53` instead — the host's LAN-facing static IP — gives AdGuard exactly the interface it needs to serve DNS to LAN clients, **without** shadowing `10.89.0.1:53`, so `aardvark-dns` keeps resolving container names for `cloudflared`. The port number stays `53` (LAN devices' DHCP-assigned DNS server can't specify a port); only the bind address narrows from `0.0.0.0` to the host's static IP.

**Diagnosing this class of bug:**
```sh
sudo ss -tulpn | grep ':53'                                                  # AdGuard should show 192.168.1.10:53, not *:53
podman run --rm --net homelab_homelab-net alpine nslookup portainer 10.89.0.1  # must resolve, not NXDOMAIN
```

### Web UI: LAN-Only, Never Internet
**No `ADGUARD_SUBDOMAIN` in `.env`, no Cloudflare Public Hostname rule for this service — deliberate, not an oversight.** AdGuard's web UI is the control panel for the network's DNS/ad-blocking — exposing it to the internet would let anyone who finds the subdomain attempt to log in and repoint every device's DNS resolution. Since its entire purpose is *local* network service, LAN-only access is both sufficient and strictly safer; the tunnel pattern used for Portainer/Gitea/n8n/Glances is intentionally **not** repeated here.

### Port Mapping: Why `3001:80`
AdGuard's container listens on `80` internally for its permanent web UI. In dev, `docker-compose.override.yml` already maps host `3000` → Gitea. Rather than fight that conflict, AdGuard's host mapping is `3001:80` — and crucially this is placed in the **base** `docker-compose.yml` (not override), because:
- Prod needs it permanently (LAN users hit `http://192.168.1.10:3001`).
- Dev gets it "for free" at `http://localhost:3001` without any override changes.
- **`docker-compose.override.yml` needs zero changes for AdGuard** — every port it needs (`53/tcp`, `53/udp`, `3001:80`) is already in the base file and applies identically in both environments (unlike Portainer/Glances/Gitea/n8n, whose base files are port-less and rely on override for dev access).

**Note**: `adguard/adguardhome` exposes two ports for different purposes: port `3000` serves the one-time setup wizard (only active before initial configuration is saved); port `80` serves the permanent web UI after setup completes. The correct mapping for ongoing use is `3001:80`. During first-run setup, the wizard is also reachable at host port `3001` because AdGuard listens on both `3000` and `80` simultaneously until setup is complete — after which port `3000` closes.

### `.env`: No Changes Needed
No new variables required — no subdomain (LAN-only, per above), no tunnel routing, no per-env path differences for this service. Stated explicitly so it's clear this isn't a missed step.

### First-Run Flow
On first `podman-compose up`, `./data/adguard/{conf,work}` are empty — AdGuard serves a setup wizard on port `3000` (host `3001`). Visiting `http://192.168.1.10:3001` (prod) or `http://localhost:3001` (dev) walks through: admin credentials, listening interfaces (bind to all / `192.168.1.10`), upstream DNS resolvers. On completion, AdGuard writes `AdGuardHome.yaml` into `conf/` — from that point on, the container starts directly into the running service using that config.

### Backup Integration
Both directories under `./data/adguard/` need backing up:
- `conf/AdGuardHome.yaml` — DNS config, upstream resolvers, filter list subscriptions, **admin credential hash**.
- `work/` — query logs, stats DB, downloaded filter-list cache.

Single mount covers both (they share the `./data/adguard/` parent):
```yaml
- ./data/adguard:/sources/adguard:ro
```
Picked up automatically by the existing generic `/sources/*` loop — **zero `backup.sh` changes**, identical pattern to Phases 3-6.

**Restore guarantee**: copy `./data/adguard/` back, `podman-compose up -d` → AdGuard resumes with identical DNS rules, block lists (no re-download needed — cached in `work/`), query history/stats, and admin login (`AdGuardHome.yaml` password hash restored as-is).

**Tuning note (not a blocker)**: `work/`'s query-log DB grows continuously. AdGuard's UI has a log-retention setting (Settings → General → query log retention) — set a sane window (e.g. 7-30 days) to bound backup size over time. Not required for initial setup, worth doing once the UI is up.

### Docker ↔ Podman Compatibility Notes
1. **Port 53 binding (sysctl change) is Linux-only.** On macOS, podman runs inside a Linux VM (podman machine) — the same `net.ipv4.ip_unprivileged_port_start` mechanism applies *inside that VM*, but it's untested here; flagging as something to verify on first dev `up` (binding `53:53` may just work inside the VM, or may need the same sysctl tweak run via `podman machine ssh`). **Note**: the prod port mapping is now `192.168.1.10:53:53` (host LAN IP only, see "DNS Port Binding" above) — `192.168.1.10` is the Debian prod host's static IP and won't exist on a macOS dev machine. Dev `up` will fail to bind this port as-written; dev users should override to `"53:53"` (or the podman-machine VM's IP) in `docker-compose.override.yml` if testing AdGuard DNS locally.
2. **`systemd-resolved` / `/etc/resolv.conf`**: macOS has neither — no dev-side action needed, these steps are prod-only (already scoped to "Debian Prod" above).
3. **Bind mounts `./data/adguard/{conf,work}`**: same SELinux `:Z` open item as every prior phase's bind mounts — verify on first prod deploy.
4. **Root inside container**: `adguard/adguardhome` runs as root in-container (needed to bind privileged-range port 53 without relying solely on the host sysctl change, and to manage its own file permissions). Under rootless Podman, that root maps to the running user's uid via user-namespace remapping — `./data/adguard/` ends up owned by that mapped uid, consistent with the `--numeric-ids` backup design used throughout.

### Files to Change (pending approval)
- update `docker-compose.yml` — add `adguard` service (`image: adguard/adguardhome:latest`, `53:53/tcp`, `53:53/udp`, `3001:3000`, `./data/adguard/conf:/opt/adguardhome/conf`, `./data/adguard/work:/opt/adguardhome/work`, homelab-net) and append `./data/adguard:/sources/adguard:ro` to `backup` service volumes
- `docker-compose.override.yml` — **no changes** (all AdGuard ports already in base, see rationale above)
- `.env.example` — **no changes** (no subdomain/tunnel needed, see rationale above)
- update `deployment.md`:
  - new "AdGuard Host Prerequisites" section: static IP via netplan, `99-unprivileged-port.conf` sysctl, `systemd-resolved` stub disable
  - step 4 (pre-create data directories): add `./data/adguard/{conf,work}`
  - step 6 (zero-ports note): document `53` and `3001` as additional intentional base-compose exceptions (alongside Gitea's `2222`)
  - step 9 (verify checklist): add AdGuard DNS resolution check (`dig @192.168.1.10 example.com`) and UI check (`http://192.168.1.10:3001`)
- update `README.md`:
  - add `adguard` row to Services table — image `adguard/adguardhome`, no subdomain (LAN-only), dev port `3001`, data dir `./data/adguard`
  - add `http://localhost:3001` to Dev Quickstart section
  - no new rows needed in the `.env` variables table (no new vars)

Status: ✅ implemented, committed. Port corrected: 3001:3000 → 3001:80 (port 3000 is setup wizard only; permanent web UI is port 80). DNS port corrected: 53:53 → 192.168.1.10:53:53 (0.0.0.0:53 shadowed aardvark-dns on 10.89.0.1, breaking cloudflared container-name resolution → 502 on all tunnel hostnames).

---

## Phase 8: Boot Persistence (systemd User Service)

### Goal
The full homelab stack must auto-start on every boot and power recovery, with zero manual intervention. The systemd configuration is committed to the repository ("baked in") — versioned alongside the compose files, ready to enable on any fresh deploy without generating anything manually.

### Problem: `restart: unless-stopped` doesn't survive reboot
Podman's `restart: unless-stopped` policy (used by every service in `docker-compose.yml`) restarts a container if it *crashes* — but after a full reboot/power loss, no Podman process is running at all to apply that policy. Someone has to manually `cd ~/homelab && podman-compose up -d`. This phase closes that gap.

### Approach: Single systemd User Service
A single systemd **user** service unit, `systemd/homelab.service`, committed to the repo at that path. The unit runs `podman-compose up -d` from the homelab directory and is managed by the non-root user's systemd session (rootless Podman constraint — no root/system units involved).

**Not used, and why:**
- **`podman generate systemd`** — generates one unit per container (7 containers = 7 generated units to track/regenerate every time `docker-compose.yml` changes). Also deprecated/discouraged in newer Podman versions.
- **Podman Quadlets** — would replace the compose files with `.container`/`.pod` unit files entirely; introduces Ubuntu-version compatibility risk on the 2013 laptop's older systemd/Podman versions, and abandons the compose-based workflow this repo is built around.

A single compose-driving unit is the smallest, most maintainable surface: one file, no regeneration, works with any future service added to `docker-compose.yml` with zero changes to this unit.

### `loginctl enable-linger` (critical prerequisite)
By default, a user's systemd **user session** only exists while that user is logged in — on boot, with no interactive login, user units never start, no matter what they contain.

```sh
loginctl enable-linger <user>
```

This is a **one-time host command**, not a file — it's not part of the unit and isn't committed to the repo. It tells systemd-logind to start `<user>`'s systemd user instance at boot regardless of login state. **Without this, `systemd/homelab.service` does nothing on reboot** — it would only ever run if/when the user logs in. This is the single most critical enabler for this entire phase, and is handled by `run.sh`.

### `systemd/homelab.service` — Unit File
```ini
[Unit]
Description=Homelab podman-compose stack
After=network-online.target podman.socket
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/homelab
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=default.target
```

**Field-by-field rationale:**
- `After=network-online.target` + `Wants=network-online.target` — network must be fully up before starting; critical for AdGuard (binds port 53) and `cloudflared` (must reach Cloudflare's edge to establish the tunnel). `Wants=` ensures systemd actually pulls in and waits for this target, not just orders against it.
- `After=podman.socket` — ensures the rootless Podman socket is ready before `podman-compose` runs (Portainer also depends on this socket).
- `Type=oneshot` — `podman-compose up -d` starts containers detached and exits; systemd doesn't need to track a long-running process for *this* unit — the containers' own `restart: unless-stopped` policy handles them after.
- `RemainAfterExit=yes` — tells systemd the service stays "active" after the oneshot exits, so `systemctl status` correctly shows it as running, and `systemctl stop` correctly triggers `ExecStop`.
- `WorkingDirectory=%h/homelab` — `%h` expands to the user's home directory; keeps the unit portable across usernames without hardcoding `/home/<user>`.
- `ExecStart=/usr/bin/podman-compose up -d` / `ExecStop=/usr/bin/podman-compose down` — full paths, since systemd units do not inherit `$PATH` from a user shell.
- `Restart=on-failure` + `RestartSec=10s` — if `podman-compose up -d` itself fails (e.g. Podman socket not actually ready yet despite `After=` ordering), retry after a 10s backoff rather than tight-looping.
- `TimeoutStartSec=120` — allows up to 2 minutes for all containers to start; first-run image pulls on 2013-era hardware can be slow.
- `WantedBy=default.target` — the correct enable target for **user** services (the user-session equivalent of `multi-user.target`).

### `podman-compose` Path Note
`/usr/bin/podman-compose` may not be correct on every system — some installs place it in `/usr/local/bin/`. Verify with `which podman-compose` before relying on the unit; if it differs, update `ExecStart=`/`ExecStop=` in `systemd/homelab.service`. Similarly, `WorkingDirectory=%h/homelab` assumes the repo is cloned to `~/homelab` — if cloned elsewhere, update `WorkingDirectory=` in the unit file.

### macOS Dev: Not Applicable
systemd is Linux-only. macOS dev users continue to start the stack manually with `podman-compose up -d`, as before — **no dev-side changes**.

### Docker ↔ Podman Compatibility Notes
1. **Binary path (`podman-compose` vs `docker-compose`)**: prod uses `podman-compose`; if `docker-compose` is ever substituted, `ExecStart=`/`ExecStop=` paths in `systemd/homelab.service` must be updated to match.
2. **`loginctl enable-linger`**: a systemd/logind concept, Linux-only — no macOS equivalent, no action needed in dev.
3. **`network-online.target`**: on some minimal Ubuntu installs this target isn't pulled in by default. Verify/enable the network-manager-appropriate waiter:
   ```sh
   sudo systemctl enable systemd-networkd-wait-online.service
   # or, if using NetworkManager instead of networkd:
   sudo systemctl enable NetworkManager-wait-online.service
   ```
4. **Relationship to `restart: unless-stopped`**: these two layers are complementary, not redundant. `restart: unless-stopped` (in `docker-compose.yml`) handles *individual container crashes* while Podman is already running — Podman itself restarts the crashed container. `homelab.service` handles the *stack-level* cold start after a reboot/power loss, when no Podman process exists yet to apply any restart policy at all.

### Supersedes: `podman-restart.service` Approach (Phase 7 / `run.sh`)
This phase **replaces** the boot-persistence mechanism introduced alongside Phase 7 (`run.sh` enabling Podman's built-in `podman-restart.service`). Running both `podman-restart.service` and `homelab.service` would create two competing boot-start paths for the same containers (race/double-start risk). `run.sh` and `deployment.md` drop the `podman-restart.service` enable step in favor of enabling `homelab.service`. `loginctl enable-linger` and `systemctl --user enable --now podman.socket` remain required (linger for the reason above; `podman.socket` because Portainer talks to it and `homelab.service`'s `After=podman.socket` depends on it existing).

### Files to Change (pending approval)
- new `systemd/homelab.service` — the unit file above, committed to the repo
- update `run.sh` — replace the `podman-restart.service` enable step with `systemctl --user daemon-reload` + `systemctl --user enable --now homelab.service`; keep `loginctl enable-linger` and `podman.socket` enable
- update `deployment.md`:
  - new "Boot Persistence (Auto-start)" section (replaces "Why no `podman generate systemd`?"): rationale, enable/verify/journalctl/stop-start commands, path-verification note
  - step 7 description: `podman-restart.service` → `homelab.service`
  - step 8 (Verify) checklist: `podman-restart.service` → `homelab.service`
- update `README.md` — new "Boot Persistence" section pointing to `systemd/homelab.service` + deployment.md; Dev Quickstart note that auto-start is Linux/prod-only

Status: ✅ implemented, committed.

---

## Phase 9: Persistent Backup Storage (USB)

### Goal
Guarantee `/mnt/usb-disk` (the `backup` container's `BACKUP_DEST_PATH`) is a stable, writable mount point that survives reboots and USB re-enumeration — the backup container must never start against a missing or wrong destination.

### Rationale: UUID-based fstab vs `/dev/sdX`
Linux assigns `/dev/sdX` (or `/dev/sdaX`) names by enumeration order at boot — this order isn't guaranteed, especially with multiple USB devices or after a drive is unplugged/replugged into a different port. A `/etc/fstab` entry keyed on `/dev/sdX` can silently mount the *wrong* device, or fail to mount at all, after a reboot.

Filesystem UUIDs are generated at format time and embedded in the filesystem itself — they don't change regardless of port, enumeration order, or which other USB devices are attached. Mounting by `UUID=` in `/etc/fstab` guarantees `/mnt/usb-disk` always points at the correct physical drive.

Combined with:
- **`nofail`** — if the drive is ever missing at boot, the system still boots normally (the `backup` container will simply fail to find `/mnt/usb-disk` and can be addressed manually, rather than the whole host hanging on a missing mount).
- **`uid=1000,gid=1000`** — the mount itself is owned by the host's uid 1000 (the same uid rootless Podman maps container processes to, per Phase 2/n8n precedent), so the `backup` container's bind mount (`${BACKUP_DEST_PATH}:/backup`) is always writable without per-boot `chown`.

This makes the backup destination a fixed, predictable property of the host — `docker-compose.yml` and `.env` (`BACKUP_DEST_PATH=/mnt/usb-disk`, set in Phase 2) need no changes; this phase only hardens the host-side mount that path already assumed existed.

### Files to Change (pending approval)
- update `deployment.md` — new "Phase 9: Persistent Backup Storage (USB)" section (identify via `lsblk -f`, create mount point, `/etc/fstab` UUID entry with `nofail,uid=1000,gid=1000`, `mount -a` + `df -h` verify, `chown`)
- `docker-compose.yml` — **no changes** (`BACKUP_DEST_PATH=/mnt/usb-disk` already wired in Phase 2)
- `.env.example` — **no changes**

Status: ✅ implemented, committed.

---

## Phase 10: Hardened USB Backup Storage & Mount-Guard

### Goal
Close a silent-data-loss gap in the Phase 2 backup sidecar: if `/mnt/usb-disk` is not actually mounted, `backup.sh` currently rsyncs straight onto the host's root filesystem with no error. This phase adds a mount guard to `backup.sh`, an `ext4` + `x-systemd.automount` fstab recipe (superseding Phase 9's basic fstab entry), and a dev/prod-aware `BACKUP_REQUIRE_MOUNT` toggle so the guard doesn't fire against `./mock-usb` in dev.

### Critical Gap: `backup.sh` Has No Mount Check
Current flow when `/mnt/usb-disk` is **not** mounted on the host:
- `/mnt/usb-disk` exists as an empty directory (created once, per Phase 9 step 2).
- The compose volume `${BACKUP_DEST_PATH}:/backup` binds the container's `/backup` to that empty *host directory* — not the USB filesystem.
- `backup.sh` sees `/backup` as a normal writable directory and runs `rsync` successfully.
- All service data gets rsync'd onto the host's **root filesystem** under `/mnt/usb-disk/...`. The USB receives nothing.
- No error, no log entry, no alert. Root filesystem fills up silently over time — on a small 2013-laptop disk, this can eventually take down the whole stack.

### The Fix: `mountpoint -q` Guard
```sh
# Safety: abort if /backup is not a real mount point.
# Without this, a missing USB mount would silently rsync all data onto
# the host's root filesystem instead of the USB drive.
if [ "$BACKUP_REQUIRE_MOUNT" = "true" ] && ! mountpoint -q "$DEST_ROOT"; then
  echo "[$(date)] ERROR: $DEST_ROOT is not a mount point. USB drive not mounted? Aborting backup to prevent filling host filesystem." >> /var/log/backup.log
  exit 1
fi
```
Placed at the top of `backup.sh`, before the `rsync` loop.

**Why `mountpoint -q` and not the alternatives:**
- **`[ -d "$DEST_ROOT" ]` (directory exists)** — always true in the failure scenario above; the empty placeholder directory *is* a directory. This check would pass even when the USB is unmounted — useless as a guard.
- **`[ -w "$DEST_ROOT" ]` (writable)** — also always true; the host directory is owned by the host user and writable regardless of whether the USB is mounted over it. Would also pass in the failure scenario.
- **`mountpoint -q "$DEST_ROOT"`** — checks whether `$DEST_ROOT` is the root of a *distinct mounted filesystem* (compares device/inode of the path against its parent). This is the only check that actually distinguishes "USB mounted here" from "empty placeholder directory" — exactly the failure mode in question. `-q` suppresses output; only the exit code is used. `mountpoint` is a busybox applet, already present in the `alpine:latest` base image — no new package needed.

**Exit paths:**
- **Guard passes** (`/backup` is a real mountpoint, or `BACKUP_REQUIRE_MOUNT != "true"`) — script proceeds to the existing `rsync` loop as today.
- **Guard fails** (`BACKUP_REQUIRE_MOUNT=true` and `/backup` is not a mountpoint) — logs a clear timestamped error to `/var/log/backup.log` and `exit 1`. The cron job's `>> /var/log/backup.log 2>&1` redirect (per `backup/crontab`) captures this; `crond -f -l 2` surfaces it in `podman logs backup`. The container itself keeps running (cron daemon is PID 1, unaffected by one job's exit code) — next scheduled run (03:00) retries the same check, so once the USB is mounted, backups resume automatically with no container restart needed.

### USB Setup (Host-Side)

#### Filesystem Choice: `ext4`
`ext4` is required, not just recommended, given `backup.sh`'s `rsync -aAXH --numeric-ids` flags (Phase 2):
- `-A` (ACLs) and `-X` (extended attributes) have **no equivalent on FAT32/exFAT** — rsync would silently drop these attributes on every backup, breaking Phase 2's "drop-in restore, zero permission errors" guarantee.
- Native Linux filesystem — no extra drivers/packages on Debian/Ubuntu.
- Journaling avoids `fsck` delays after an unclean unmount (power loss is a real scenario on this hardware).

#### Formatting a Fresh Drive (destructive — one-time)
```sh
lsblk -f   # identify the correct partition first — check LABEL/SIZE carefully
sudo mkfs.ext4 -L homelab-backup /dev/sdX1   # replace /dev/sdX1 with the actual partition
```
**This destroys all existing data on the partition.** The `-L homelab-backup` label lets you re-identify the correct drive later via `lsblk -f` (LABEL column) — important once multiple USB devices are involved, to avoid formatting the wrong one.

#### UUID-Based fstab with `x-systemd.automount`
```sh
lsblk -f                  # note UUID and FSTYPE (ext4) of the labeled partition
sudo mkdir -p /mnt/usb-disk
```
`/etc/fstab` entry:
```
UUID=<uuid> /mnt/usb-disk ext4 defaults,nofail,x-systemd.automount 0 2
```
- **`nofail`** — boot continues even if the USB is unplugged. Without this, a missing drive can hang/fail the boot entirely, preventing *every* service (including AdGuard DNS) from starting — unacceptable for a drive that's removable by design.
- **`x-systemd.automount`** — systemd mounts `/mnt/usb-disk` on first access rather than unconditionally at boot. Combined with `nofail`, this is the cleanest behavior: if the drive isn't present, the mount is simply skipped at boot (no error, no hang); the `backup.sh` guard above is what actually catches the missing mount, at the time it matters (backup run).
- **`0 2`** — no `dump`; `fsck` after the root filesystem on boot (standard for secondary partitions).
- **No `uid=`/`gid=`** — these are vfat/exfat/ntfs-3g mount options. ext4 stores ownership in on-disk inodes, not as a mount-time mapping; `uid=`/`gid=` on an ext4 fstab line are ignored or rejected. Ownership is set once via `chown` after mounting (next step) — same mechanism as the existing Phase 9 step 5, carried forward unchanged.

Mount and set ownership:
```sh
sudo mount -a
sudo chown -R 1000:1000 /mnt/usb-disk
df -h                  # confirm /mnt/usb-disk, correct size
ls -la /mnt/usb-disk   # confirm owned by uid 1000
```

### `run.sh` Integration
New step inserted between the linger/systemd-enable step and the final `podman-compose up -d` step (renumbered `[n/7]` → `[n/8]`):
```sh
echo "==> [7/8] Checking USB backup mount..."
if ! mountpoint -q /mnt/usb-disk; then
  echo "WARNING: /mnt/usb-disk is not mounted. Backup will not write to USB."
  echo "Ensure fstab entry is correct and run: sudo mount -a"
  echo "Continuing stack bring-up — backup container will abort each run"
  echo "until the drive is mounted. See deployment.md Phase 9/10."
else
  echo "/mnt/usb-disk mounted OK."
fi
```
**Warning, not abort** — `cloudflared`, AdGuard, Gitea, n8n, etc. must still come up even if the USB isn't ready yet. Only the `backup` container's scheduled rsync runs are affected, and now fail *safely* (via the `backup.sh` guard) instead of silently writing to the host root filesystem.

### Dev vs Prod: `BACKUP_REQUIRE_MOUNT`

| Setting | Dev (macOS) | Prod (Ubuntu) |
|---|---|---|
| `BACKUP_DEST_PATH` | `./mock-usb` | `/mnt/usb-disk` |
| `BACKUP_REQUIRE_MOUNT` | `false` | `true` |
| Mount guard behavior | skipped — `./mock-usb` is intentionally a plain dir, not a mountpoint | enforced — `/backup` must be a real mountpoint or backup aborts |

`./mock-usb` is deliberately a plain directory (Phase 2 dev convenience) — `mountpoint -q ./mock-usb` would always fail there, so the guard must be opt-in via env var, not unconditional.

`.env.example` addition:
```
BACKUP_REQUIRE_MOUNT=false   # dev: mock-usb is a plain dir, skip guard
# BACKUP_REQUIRE_MOUNT=true  # prod: enforce USB mount — uncomment on server
```

`docker-compose.yml` — `backup` service gains:
```yaml
environment:
  - BACKUP_REQUIRE_MOUNT=${BACKUP_REQUIRE_MOUNT:-false}
```
The `:-false` default means dev works out of the box with no `.env` change; prod must explicitly set `BACKUP_REQUIRE_MOUNT=true`.

### Docker ↔ Podman Compatibility Notes
1. `mountpoint` is a busybox applet already present in `alpine:latest` — no Dockerfile change, identical on both platforms.
2. `environment:` var with `${VAR:-default}` compose syntax — identical behavior in `docker-compose` and `podman-compose`.
3. `x-systemd.automount` and `/etc/fstab` are host-OS concepts — Debian/Ubuntu prod only, no macOS equivalent (macOS dev continues using `./mock-usb`, a plain bind-mounted directory, unaffected by this phase).

### Files to Change (pending approval)
- `backup/backup.sh` — add `BACKUP_REQUIRE_MOUNT`-gated `mountpoint -q "$DEST_ROOT"` guard before the rsync loop
- `docker-compose.yml` — add `environment: - BACKUP_REQUIRE_MOUNT=${BACKUP_REQUIRE_MOUNT:-false}` to the `backup` service
- `.env.example` — add `BACKUP_REQUIRE_MOUNT=false` (dev) with prod `# BACKUP_REQUIRE_MOUNT=true` comment
- `run.sh` — new "USB mount sanity check" step (warning-only) between the linger/systemd-enable step and the final `podman-compose up -d`; renumber `[n/7]` → `[n/8]`
- `deployment.md` — rewrite "Phase 9: Persistent Backup Storage (USB)": `mkfs.ext4` formatting (destructive, `-L homelab-backup`), fstab `defaults,nofail,x-systemd.automount` (no `uid=`/`gid=` — ext4 ignores them), `sudo chown -R 1000:1000 /mnt/usb-disk` as the ownership step, `ext4` rationale (FAT32/exFAT xattr warning), reference to `backup.sh` mount guard + `BACKUP_REQUIRE_MOUNT`; update step 7 to mention new run.sh USB check
- `README.md` — Backup & Restore section: note `ext4` requirement, `BACKUP_REQUIRE_MOUNT=true` in prod, mount-guard safe-abort behavior; add `BACKUP_REQUIRE_MOUNT` row (`false` / `true`) to the Environment Variables table
- `architecture.md` — append this Phase 10 section; Phase 9 stays as-is (basic fstab rationale), Phase 10 supersedes its fstab recipe with the `ext4`/`x-systemd.automount` version and adds the mount-guard/`BACKUP_REQUIRE_MOUNT` layer on top

Status: ✅ implemented, committed.
