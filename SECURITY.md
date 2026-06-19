# Security Baseline

LocalCloud Stack is designed for private data. It can reduce exposure, but operators are still responsible for host security, Cloudflare policies, secrets, and backups.

## Exposure Policy

- Publish web apps through Cloudflare Tunnel.
- Protect admin-style apps with Cloudflare Access and MFA.
- Keep Portainer disabled unless needed.
- Keep AdGuard Web UI LAN-only.
- Keep databases internal-only.
- Keep Mattermost disabled unless needed.

## Host Firewall

Default stance:

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow from <LAN_CIDR> to any port 53 proto tcp
sudo ufw allow from <LAN_CIDR> to any port 53 proto udp
sudo ufw allow from <LAN_CIDR> to any port 3001 proto tcp
sudo ufw allow from <LAN_CIDR> to any port 2222 proto tcp
sudo ufw enable
```

## Secrets

`.env` must be mode `600`.

Generate required secrets:

```sh
openssl rand -hex 32      # N8N_ENCRYPTION_KEY
openssl rand -base64 48   # RESTIC_PASSWORD
openssl rand -hex 32      # MATTERMOST_DB_PASSWORD if enabling --profile chat
```

Store `N8N_ENCRYPTION_KEY` and `RESTIC_PASSWORD` outside the backup disk. Losing either can make data unrecoverable.

## Backups

Backups are encrypted restic snapshots at `${BACKUP_DEST_PATH}/restic-repo`.

Production baseline:

- LUKS-encrypted physical backup disk.
- ext4 filesystem inside the unlocked LUKS volume.
- `BACKUP_REQUIRE_MOUNT=true`.
- Restore tested before storing important data.

## Updates

For production, replace `latest` image refs in `.env` with version tags or digests and update deliberately.

Suggested routine:

```sh
podman-compose -f docker-compose.yml pull
podman-compose -f docker-compose.yml up -d
podman image prune
```

Take a restic snapshot before updates.

## Responsible Disclosure

If you publish a fork or hosted product based on this project, add your own vulnerability reporting address here.
