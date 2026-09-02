# Architecture

LocalCloud Stack is an installable self-hosted stack for private services on user-owned hardware. The design favors low operational overhead, low idle resource use, and a narrow public attack surface.

## Deployment Model

- Ubuntu Server host.
- Non-root user owns all containers.
- Rootless Podman runs the stack.
- `install.sh` creates a user-level `localcloud.service` systemd unit for the current checkout path.
- `docker-compose.yml` is the production source of truth.
- `compose.dev.yml` is explicit and never auto-loaded.

## Network Model

| Network | Purpose |
|---|---|
| `edge-net` | services reached by Cloudflare Tunnel |
| `dns-net` | AdGuard DNS/UI |
| `mgmt-net` | Portainer and Podman socket access |
| `db-net` | internal database traffic |
| `env-net` | Infisical env store and its PostgreSQL + Redis (Tier B) |
| `appdb-net` | application database and Adminer; `internal: true`, no egress |
| `umami-net` | Umami analytics and its PostgreSQL (Tier B); `internal: true`, no egress |
| `glitchtip-net` | GlitchTip error monitoring and its PostgreSQL + Valkey (Tier B); `internal: true`, no egress |
| `tailscale0` | host interface for Tier B (Private) service binds via Tailscale |

The backup container uses `network_mode: none`.

## Exposure Model

Services follow the three-tier exposure model defined in [SECURITY.md](SECURITY.md):

- **Tier A (Public)** - published through Cloudflare Tunnel with per-hostname Access policies: Gitea HTTP, n8n, Glances, Mattermost.
- **Tier B (Private)** - reachable only through Tailscale, bound to the tailscale0 address: the `env` profile's Infisical, the `db` profile's PostgreSQL (`appdb`) and Adminer (`appdb-adminer`), the `analytics` profile's Umami, and the `monitoring` profile's GlitchTip. Gitea SSH moves here from its LAN bind later.
- **Tier C (Internal)** - never published: mattermost-postgres, infisical-postgres, umami-postgres, glitchtip-postgres, glitchtip-valkey, the `appdb-dump`, `infisical-db-dump`, `umami-db-dump`, and `glitchtip-db-dump` sidecars, backup (`network_mode: none`), Portainer (mgmt profile).

Current transitional binds: AdGuard binds DNS and UI to `LAN_IP`; Gitea SSH binds to `LAN_IP:GITEA_SSH_PORT` until the Tier B migration.

## Data Model

All persistent service data lives under `./data/<service>`. This keeps backup and restore behavior predictable. Stateful add-ons follow the same rule at the service level: each feature gets its own name-prefixed instance (`mattermost-postgres`, `infisical-postgres`, `infisical-redis`, `umami-postgres`, `glitchtip-postgres`, `glitchtip-valkey`) and profiles never share a database or cache.

Important paths:

- `./data/gitea`
- `./data/n8n`
- `./data/adguard`
- `./data/monitor`
- `./data/portainer`
- `./data/mattermost`
- `./data/infisical`
- `./data/appdb`
- `./data/umami`
- `./data/glitchtip`

## Backup Model

The backup sidecar runs cron at `03:00` in the configured `TZ`.

Flow:

1. Verify the backup-volume marker exists when `BACKUP_REQUIRE_MOUNT=true`.
2. When `monitoring` is enabled, write a logical GlitchTip PostgreSQL dump to `./data/glitchtip/db-dumps`.
3. When `analytics` is enabled, write a logical Umami PostgreSQL dump to `./data/umami/db-dumps`.
4. When `chat` is enabled, write a logical Mattermost PostgreSQL dump to `./data/mattermost/db-dumps`.
5. When `env` is enabled, write a logical Infisical PostgreSQL dump to `./data/infisical/db-dumps`.
6. When `db` is enabled, write `pg_dumpall --globals-only` plus one logical dump per application database to `./data/appdb/db-dumps`.
7. Initialize restic at `${RESTIC_REPOSITORY}` if needed.
8. Snapshot `/sources`.
9. Apply retention with daily, weekly, and monthly keep counts.

Backups are encrypted and versioned. The restic password must be stored separately from the backup disk.

## Security Defaults

- `.env` is owner-readable only.
- Gitea disables registration and requires sign-in.
- n8n uses an explicit encryption key and disables higher-risk defaults.
- Dev ports bind to `127.0.0.1`.
- Auto-loaded `docker-compose.override.yml` is ignored and rejected by the installer.

## Optional Services

Optional services are enabled through `LOCALCLOUD_PROFILES` in `.env`. The installer validates profile names, validates profile-specific secrets, and restarts the selected profile set so disabled optional containers do not keep running after configuration changes.

Examples:

- `LOCALCLOUD_PROFILES=dns` enables AdGuard.
- `LOCALCLOUD_PROFILES=mgmt` enables Portainer.
- `LOCALCLOUD_PROFILES=chat` enables Mattermost + PostgreSQL + logical dumps.
- `LOCALCLOUD_PROFILES=db` enables the application database (PostgreSQL + Adminer + logical dumps). Requires the Tailscale transport.
- `LOCALCLOUD_PROFILES=dns,chat` enables multiple profiles.
- `LOCALCLOUD_PROFILES=env` enables Infisical. Tier B only: it requires `TAILSCALE_ENABLED=true`, binds to the tailscale0 address, and is never attached to the tunnel network.
- `LOCALCLOUD_PROFILES=analytics` enables Umami web analytics (app + PostgreSQL + logical dumps). Tier B only: it requires `TAILSCALE_ENABLED=true`, binds to the tailscale0 address, and is never attached to the tunnel network.
- `LOCALCLOUD_PROFILES=monitoring` enables GlitchTip app-error monitoring (app + PostgreSQL + Valkey + logical dumps). Tier B only: it requires `TAILSCALE_ENABLED=true`, binds to the tailscale0 address, and is never attached to the tunnel network.

After editing `.env`, rerun `./install.sh` so the generated systemd user service matches the selected profiles.

## Product Direction

This project is currently a self-hosted installable stack, not SaaS. A future hosted product would need:

- user/account billing
- tenant isolation
- remote device enrollment
- update orchestration
- support and telemetry policy
- hosted control plane

Those are intentionally outside the current repository.
