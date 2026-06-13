# Homelab

Self-hosted services on a 2013 laptop (Debian + Podman, prod) / macOS (dev), exposed only via Cloudflare Tunnel — zero inbound ports except Gitea SSH.

Full design rationale, decisions, and platform-compatibility notes for each phase: [architecture.md](architecture.md).
Production deploy checklist: [deployment.md](deployment.md).

## Services

| Service | Image | Subdomain (`.env`) | External URL | Dev port | Data dir |
|---|---|---|---|---|---|
| cloudflared | `cloudflare/cloudflared` | — | (tunnel gateway) | — | — |
| portainer | `portainer/portainer-ce` | `PORTAINER_SUBDOMAIN` | `https://portainer.localcloud.example` | `9000` | `./data/portainer` |
| glances | `nicolargo/glances` | `MONITOR_SUBDOMAIN` | `https://monitor.localcloud.example` | `61208` | `./data/monitor` |
| gitea | `gitea/gitea` | `GITEA_SUBDOMAIN` | `https://git.localcloud.example` (HTTP) / `git@localcloud.example:2222` (SSH) | `3000` | `./data/gitea` |
| n8n | `n8nio/n8n` | `N8N_SUBDOMAIN` | `https://n8n.localcloud.example` | `5678` | `./data/n8n` |
| backup | (built from `./backup`) | — | — | — | writes to `BACKUP_DEST_PATH` |

All services share the `homelab-net` bridge network. Dev ports come from `docker-compose.override.yml` (auto-merged); production deletes/renames that file to stay zero-ports (see [deployment.md](deployment.md)).

## Dev Quickstart (macOS)

```sh
cp .env.example .env
# edit .env: set TUNNEL_TOKEN at minimum

podman-compose up -d
```

- Portainer: http://localhost:9000
- Glances: http://localhost:61208
- Gitea: http://localhost:3000
- n8n: http://localhost:5678

Note: temperature sensors will show empty/N/A in the macOS podman VM — expected, see [architecture.md](architecture.md) Phase 4.

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
