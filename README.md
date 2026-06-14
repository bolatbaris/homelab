# Homelab

A low-resource, rootless-Podman homelab stack for older hardware (2013 laptop, Debian prod / macOS dev) — DNS-level ad-blocking, agentic workflow orchestration (n8n), self-hosted git, container management, hardware monitoring, and self-healing nightly backups. Exposed to the internet only via Cloudflare Tunnel — zero inbound ports except Gitea SSH and LAN-only AdGuard DNS.

Full design rationale, decisions, and platform-compatibility notes for each phase: [architecture.md](architecture.md).
Production deploy checklist: [deployment.md](deployment.md).

## Services

| Service | Image | Subdomain (`.env`) | External URL | Dev port | Data dir |
|---|---|---|---|---|---|
| cloudflared | `cloudflare/cloudflared` | — | (tunnel gateway) | — | — |
| adguard | `adguard/adguardhome` | — (LAN-only, no tunnel) | `http://192.168.1.10:3001` (prod LAN) | `3001` | `./data/adguard` |
| portainer | `portainer/portainer-ce` | `PORTAINER_SUBDOMAIN` | `https://portainer.localcloud.example` | `9000` | `./data/portainer` |
| glances | `nicolargo/glances` | `MONITOR_SUBDOMAIN` | `https://monitor.localcloud.example` | `61208` | `./data/monitor` |
| gitea | `gitea/gitea` | `GITEA_SUBDOMAIN` | `https://git.localcloud.example` (HTTP) / `git@localcloud.example:2222` (SSH) | `3000` | `./data/gitea` |
| n8n | `n8nio/n8n` | `N8N_SUBDOMAIN` | `https://n8n.localcloud.example` | `5678` | `./data/n8n` |
| backup | (built from `./backup`) | — | — | — | writes to `BACKUP_DEST_PATH` |

All services share the `homelab-net` bridge network. Dev ports come from `docker-compose.override.yml` (auto-merged); production deletes/renames that file to stay zero-ports (see [deployment.md](deployment.md)).

## Quick Start

### Production (Debian, rootless Podman) — Clean Slate
```sh
git clone <repo-url> ~/homelab && cd ~/homelab
cp .env.example .env && nano .env   # fill in TUNNEL_TOKEN at minimum
chmod +x run.sh && ./run.sh
```
`run.sh` is the single host-preparation + launch step: creates `./data/*` dirs, fixes Debian's port-53 conflict (AdGuard vs `systemd-resolved`), persists the rootless-Podman sysctl for binding port 53, enables boot-persistence (`loginctl linger` + `podman-restart.service`), and brings up the full stack. See [deployment.md](deployment.md) for the full annotated checklist (static IP, sensors, USB backup mount — the parts `run.sh` intentionally doesn't touch).

### Dev (macOS)
```sh
cp .env.example .env
# edit .env: set TUNNEL_TOKEN at minimum

podman-compose up -d
```
- Portainer: http://localhost:9000
- Glances: http://localhost:61208
- Gitea: http://localhost:3000
- n8n: http://localhost:5678
- AdGuard: http://localhost:3001

Note: temperature sensors will show empty/N/A in the macOS podman VM — expected, see [architecture.md](architecture.md) Phase 4.

Note: AdGuard DNS (port 53) may require a sysctl tweak inside the podman machine VM on macOS — see architecture.md Phase 7 if port 53 binding fails on first dev up. (`run.sh` is Debian-only; don't run it on macOS — it edits `/etc/resolv.conf` and `systemd-resolved` config that don't apply there.)

## Environment Variables (`.env`)

| Variable | Dev (macOS) | Prod (Debian) |
|---|---|---|
| `TUNNEL_TOKEN` | Cloudflare Tunnel token (required, never commit) | same |
| `BACKUP_DEST_PATH` | `./mock-usb` | `/mnt/usb-disk` |
| `BASE_DOMAIN` | `localcloud.example` | same |
| `PORTAINER_SUBDOMAIN` | `portainer` | same |
| `MONITOR_SUBDOMAIN` | `monitor` | same |
| `GITEA_SUBDOMAIN` | `git` | same |
| `N8N_SUBDOMAIN` | `n8n` | same |
| `PODMAN_SOCKET_PATH` | mac podman-machine socket (see `.env.example` comment) | `/run/user/1000/podman/podman.sock` |

## Backup & Restore

The `backup` container rsyncs every `./data/<service>` directory to `BACKUP_DEST_PATH` nightly at 03:00 Europe/Istanbul, preserving permissions/ownership/ACLs/xattrs via `--numeric-ids` (see [architecture.md](architecture.md) Phase 2).

**Restore on a new host:**
1. Copy backed-up `<service>/` dirs back into `./data/<service>/`.
2. `podman-compose up -d` — services resume with identical data, credentials, and permissions.
