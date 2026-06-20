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

Enable optional services with `LOCALCLOUD_PROFILES` (comma-separated): `dns`, `mgmt`, `chat`. Set `PODMAN_SOCKET_PATH` only for `mgmt`, and `MATTERMOST_DB_PASSWORD` only for `chat`.

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

The port 53 and 3001 rules are only needed when the `dns` profile (AdGuard) is enabled; port 2222 is Gitea SSH. Drop the rules for services you do not run.

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

`install.sh` writes a `.localcloud-backup-volume` marker onto the mounted disk; the backup container checks for it and aborts (instead of writing to the host filesystem) if the disk is ever not mounted.

## 6. Cloudflare

Create tunnel public hostnames:

- `monitor.${BASE_DOMAIN}` -> `http://glances:61208`
- `git.${BASE_DOMAIN}` -> `http://gitea:3000`
- `n8n.${BASE_DOMAIN}` -> `http://n8n:5678`

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
- starts the stack with any enabled profiles

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

Profile services appear only when enabled via `LOCALCLOUD_PROFILES`: `adguard` (`dns`), `portainer` (`mgmt`), `mattermost` + `mattermost-postgres` (`chat`). When the `dns` profile is enabled, also verify AdGuard:

```sh
dig @"$LAN_IP" example.com
curl -I "http://$LAN_IP:${ADGUARD_WEB_PORT:-3001}"
```

## 9. Optional Profiles

Portainer:

```sh
podman-compose -f docker-compose.yml --profile mgmt up -d portainer
```

Mattermost:

```sh
podman-compose -f docker-compose.yml --profile chat up -d mattermost-postgres mattermost
```

## 10. Restore

The helper restores with the correct rootless-Podman ownership and keeps your current data aside:

```sh
cd ~/localcloud-stack
./restore.sh            # latest snapshot
./restore.sh <id>       # a specific snapshot from `restic snapshots`
```

Manual equivalent — note the `podman unshare`, required so restored files get the user-namespace ownership the containers expect (a plain non-root restore cannot set those owners):

```sh
cd ~/localcloud-stack
export RESTIC_PASSWORD='<saved password>'
export RESTIC_REPOSITORY=/mnt/usb-disk/restic-repo
restic snapshots
podman unshare restic restore latest --target ./.restore
podman-compose -f docker-compose.yml down
podman unshare mv ./.restore/sources/<service> ./data/<service>
podman-compose -f docker-compose.yml up -d
```

Restore requires the **same** `.env` secrets as the original deployment — especially `RESTIC_PASSWORD` (to open the repo) and `N8N_ENCRYPTION_KEY` / `MATTERMOST_DB_PASSWORD` (to decrypt restored credentials).
