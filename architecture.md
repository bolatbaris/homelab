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

Awaiting approval before implementation.
