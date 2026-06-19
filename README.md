# LocalCloud Stack

LocalCloud Stack is a self-hosted home/server stack for people who want private services on their own hardware without opening a broad public attack surface. It uses rootless Podman, Cloudflare Tunnel, LAN-only DNS, encrypted backups, and opt-in management/chat profiles.

This is not a hosted SaaS product. It is installable self-hosted software: users run it on their own Ubuntu Server machine with `./install.sh`.

## What It Includes

| Service | Purpose | Default Exposure |
|---|---|---|
| cloudflared | Cloudflare Tunnel gateway | outbound-only |
| AdGuard Home | LAN DNS and ad blocking | `${LAN_IP}:53`, `${LAN_IP}:${ADGUARD_WEB_PORT}` |
| Glances | lightweight host monitoring | Cloudflare Tunnel, protect with Access |
| Gitea | self-hosted Git | Cloudflare Tunnel for HTTP, LAN-bound SSH |
| n8n | workflow automation | Cloudflare Tunnel, protect UI with Access |
| restic backup sidecar | encrypted, versioned backups | no network |

Optional profiles:

| Profile | Services | Default |
|---|---|---|
| `mgmt` | Portainer | off |
| `chat` | Mattermost + Postgres | off |

## Requirements

- Ubuntu Server
- Podman and podman-compose
- Cloudflare account and Tunnel token
- Static LAN IP for the server
- USB or external disk for backups

## Install

```sh
git clone <repo-url> localcloud-stack
cd localcloud-stack
./install.sh
```

The first run creates `.env` and stops. Edit `.env`, then run:

```sh
./install.sh
```

Minimum required `.env` values:

- `TUNNEL_TOKEN`
- `LAN_IP`
- `BASE_DOMAIN`
- `N8N_ENCRYPTION_KEY`
- `RESTIC_PASSWORD`
- `BACKUP_DEST_PATH`

`PODMAN_SOCKET_PATH` is required only when enabling the optional `mgmt` profile for Portainer.

Generate secrets:

```sh
openssl rand -hex 32      # N8N_ENCRYPTION_KEY
openssl rand -base64 48   # RESTIC_PASSWORD
```

## Development

Use the explicit dev compose file. It binds dev ports to `127.0.0.1` only.

```sh
podman-compose -f docker-compose.yml -f compose.dev.yml up -d
```

Optional Portainer:

```sh
podman-compose -f docker-compose.yml -f compose.dev.yml --profile mgmt up -d
```

Optional Mattermost:

```sh
podman-compose -f docker-compose.yml -f compose.dev.yml --profile chat up -d
```

## Security Model

- Web services are intended to be exposed through Cloudflare Tunnel.
- Admin-style apps should be protected by Cloudflare Access and MFA.
- Portainer is opt-in because it controls the Podman API socket.
- Mattermost is opt-in because it adds public attack surface and a database sidecar.
- Backups are encrypted restic snapshots, not plain folder mirrors.
- `docker-compose.override.yml` is ignored because Compose auto-loads it.

See [SECURITY.md](SECURITY.md) for the deployment baseline.

## Backups

The backup container runs nightly at `03:00` in the configured `TZ`, initializes an encrypted restic repository under `${BACKUP_DEST_PATH}/restic-repo`, and keeps daily, weekly, and monthly snapshots according to `.env`.

Restore outline:

```sh
export RESTIC_PASSWORD='<saved password>'
restic -r /mnt/usb-disk/restic-repo snapshots
restic -r /mnt/usb-disk/restic-repo restore latest --target /tmp/localcloud-restore
rsync -aAXH --numeric-ids /tmp/localcloud-restore/sources/<service>/ ./data/<service>/
podman-compose -f docker-compose.yml up -d
```

## Documentation

- [Deployment Runbook](deployment.md)
- [Architecture](architecture.md)
- [Security Baseline](SECURITY.md)
- [Security And Watts Difference Report](security-watts-difference-report.md)

## License

MIT. See [LICENSE](LICENSE).
