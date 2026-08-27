# Deployment Runbook

This runbook targets Ubuntu Server with rootless Podman. Run commands as the non-root user that owns the containers.

## 1. Install System Packages

```sh
sudo apt update
sudo apt install -y podman podman-compose git curl lm-sensors restic cryptsetup ufw
```

## 2. Clone And Prepare

```sh
git clone https://github.com/bolatbaris/homelab.git localcloud-stack
cd localcloud-stack
./install.sh
```

The first run creates `.env`. Edit it with real values:

```sh
nano .env
chmod 600 .env
```

Required production values:

- `TUNNEL_TOKEN=<Cloudflare tunnel token>`
- `LAN_IP=<static server LAN IP>`
- `BASE_DOMAIN=<domain you control>`
- `BACKUP_DEST_PATH=/mnt/usb-disk`
- `BACKUP_REQUIRE_MOUNT=true`
- `RESTIC_PASSWORD=<openssl rand -base64 48>`
- `N8N_ENCRYPTION_KEY=<openssl rand -hex 32>`

Enable optional services with `LOCALCLOUD_PROFILES` (comma-separated): `dns`, `mgmt`, `chat`. Invalid profile names fail the installer. Set `PODMAN_SOCKET_PATH` only for `mgmt`, and `MATTERMOST_DB_PASSWORD` plus `MATTERMOST_SUBDOMAIN` only for `chat`.

## 3. Static LAN IP

Configure a static server IP using your network manager or netplan. Example:

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
          via: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

Apply with:

```sh
sudo netplan apply
```

Also reserve or exclude the same address in your router DHCP settings.

## 4. Firewall

Adjust the LAN CIDR and ports to match `.env`.

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow from 192.168.1.0/24 to any port 53 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 53 proto udp
sudo ufw allow from 192.168.1.0/24 to any port 3001 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 2222 proto tcp
sudo ufw enable
sudo ufw status verbose
```

The port 53 and 3001 rules are only needed when the `dns` profile (AdGuard) is enabled; port 2222 is Gitea SSH. The `tailscale0` rule (`sudo ufw allow in on tailscale0`) is only needed once the Private tier transport is installed - see section 11. Drop the rules for services you do not run.

## 5. Encrypted Backup Disk

Use LUKS plus ext4. The following is destructive if pointed at the wrong disk.

```sh
lsblk -f
sudo cryptsetup luksFormat /dev/sdX1
sudo cryptsetup open /dev/sdX1 localcloud-backup
sudo mkfs.ext4 -L localcloud-backup /dev/mapper/localcloud-backup
sudo mkdir -p /mnt/usb-disk
sudo mount /dev/mapper/localcloud-backup /mnt/usb-disk
sudo chown -R "$(id -u):$(id -g)" /mnt/usb-disk
```

Verify:

```sh
mountpoint -q /mnt/usb-disk
df -h /mnt/usb-disk
```

`install.sh` writes a `.localcloud-backup-volume` marker onto the mounted disk. With `BACKUP_REQUIRE_MOUNT=true`, the installer fails if the disk is not mounted, and the backup container aborts (instead of writing to the host filesystem) if the marker is ever missing.

## 6. Cloudflare

Create tunnel public hostnames:

- `monitor.${BASE_DOMAIN}` -> `http://glances:61208`
- `git.${BASE_DOMAIN}` -> `http://gitea:3000`
- `n8n.${BASE_DOMAIN}` -> `http://n8n:5678`
- `mattermost.${BASE_DOMAIN}` -> `http://mattermost:8065` when `LOCALCLOUD_PROFILES` includes `chat`

Recommended Cloudflare Access policies:

- Require Access + MFA for monitoring.
- Require Access + MFA for the n8n UI.
- Bypass only the exact n8n webhook paths that need unauthenticated callers.
- Do not expose Portainer unless you deliberately enable `--profile mgmt` and protect it with Access + MFA.

## 7. Install

```sh
./install.sh
```

The installer:

- validates `.env` (including per-profile secrets)
- creates private data directories
- fixes rootless Podman UID mappings for n8n and Mattermost data
- reconfigures the host resolver for AdGuard only when the `dns` profile is enabled
- creates the backup-volume marker when the backup disk is mounted
- enables rootless `podman.socket`
- creates a user systemd service for the current checkout path (honoring `LOCALCLOUD_PROFILES`)
- stops any old LocalCloud containers and starts the selected profile set through the user systemd service

## 8. Verify

```sh
systemctl --user status localcloud.service
podman-compose -f docker-compose.yml ps
```

Expected base services:

- cloudflared
- glances
- gitea
- n8n
- backup

Profile services appear only when enabled via `LOCALCLOUD_PROFILES`: `adguard` (`dns`), `portainer` (`mgmt`), `mattermost` + `mattermost-postgres` + `mattermost-postgres-dump` (`chat`). When the `dns` profile is enabled, also verify AdGuard:

```sh
dig @"$LAN_IP" example.com
curl -I "http://$LAN_IP:${ADGUARD_WEB_PORT:-3001}"
```

When the `chat` profile is enabled, verify the logical chat-history dump sidecar:

```sh
podman-compose -f docker-compose.yml --profile chat ps mattermost-postgres-dump
ls -lh ./data/mattermost/db-dumps/
```

## 9. Optional Profiles

Portainer:

```sh
podman-compose -f docker-compose.yml --profile mgmt up -d portainer
```

Mattermost:

```sh
podman-compose -f docker-compose.yml --profile chat up -d mattermost-postgres mattermost-postgres-dump mattermost
```

## 10. Restore

The helper restores with the correct rootless-Podman ownership and keeps your current data aside:

```sh
cd ~/localcloud-stack
./restore.sh            # latest snapshot
./restore.sh <id>       # a specific snapshot from `restic snapshots`
```

Manual equivalent - note the `podman unshare`, required so restored files get the user-namespace ownership the containers expect (a plain non-root restore cannot set those owners). Add the same `--profile ...` flags you enabled in `.env`:

```sh
cd ~/localcloud-stack
export RESTIC_PASSWORD='<saved password>'
export RESTIC_REPOSITORY=/mnt/usb-disk/restic-repo
PROFILE_ARGS='--profile dns --profile chat'  # adjust or leave empty
restic snapshots
podman unshare restic restore latest --target ./.restore
podman-compose -f docker-compose.yml $PROFILE_ARGS down
podman unshare mv ./.restore/sources/<service> ./data/<service>
podman-compose -f docker-compose.yml $PROFILE_ARGS up -d
```

Restore requires the **same** `.env` secrets as the original deployment - especially `RESTIC_PASSWORD` (to open the repo) and `N8N_ENCRYPTION_KEY` / `MATTERMOST_DB_PASSWORD` (to decrypt restored credentials).

The scheduled backup is file-level. For the strongest restore consistency before major upgrades, stop write-heavy services, run `podman exec backup /usr/local/bin/backup.sh`, then start the services again.

Mattermost chat history lives in PostgreSQL. With the `chat` profile enabled, `mattermost-postgres-dump` creates `./data/mattermost/db-dumps/mattermost-latest.dump` before the default restic snapshot. If a raw PostgreSQL data restore ever fails, rebuild the Mattermost database from that dump with `pg_restore` against a clean `mattermost-postgres` container.

## 11. Private Tier (Tailscale)

Optional. Enables the Private (Tier B) exposure tier - see [SECURITY.md](SECURITY.md) for the policy and [docs/tailscale.md](docs/tailscale.md) for the design.

1. Install and authenticate on the host:

   ```sh
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```

   Use an SSO account protected by MFA. In the admin console: least-privilege ACLs, key expiry disabled for this server node only, MagicDNS on, "Override local DNS" OFF for this server (the `dns` profile owns `/etc/resolv.conf`). No subnet routing.

2. Firewall:

   ```sh
   sudo ufw allow in on tailscale0
   ```

3. Set in `.env`:

   ```
   TAILSCALE_ENABLED=true
   ```

   `TAILSCALE_IP` can stay empty: `./install.sh` detects the tailscale0 IPv4, validates it, and writes it back to `.env` for Tier B service binds. A pre-set `TAILSCALE_IP` must match the detected address or the installer fails.

4. Rerun `./install.sh`. The installer fails closed when `TAILSCALE_ENABLED=true` but the `tailscale` binary is missing or the node has no tailscale0 address.

Verify from an enrolled device on a foreign network:

```sh
tailscale status
ssh <tailscale-ip>
```

On the server, confirm Tier B services (when introduced) bind only to the tailscale address:

```sh
ss -tlnp | grep <port>   # foreign address must be the 100.x tailscale IP, never 0.0.0.0
```

Rollback: `sudo tailscale down`, remove the ufw rule, set `TAILSCALE_ENABLED=false`, rerun `./install.sh`.
