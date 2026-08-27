# Deployment Runbook

This runbook targets Ubuntu Server with rootless Podman. Run commands as the non-root user that owns the containers.

## 1. Install System Packages

```sh
sudo apt update
sudo apt install -y podman podman-compose git curl lm-sensors restic cryptsetup ufw dbus-user-session
```

Optional profiles need `--profile` support, which landed in podman-compose 1.1.0. Ubuntu 24.04 ships 1.0.6, so check and upgrade if `LOCALCLOUD_PROFILES` is not empty:

```sh
podman-compose --version
podman-compose --help | grep -- --profile   # no output means no profile support
```

Upgrade path:

```sh
sudo apt remove -y podman-compose
sudo apt install -y pipx && pipx ensurepath
pipx install podman-compose
exec "$SHELL" -l
```

`install.sh` fails closed with an explicit message when profiles are configured but the installed podman-compose cannot handle them.

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

The port 53 and 3001 rules are only needed when the `dns` profile (AdGuard) is enabled; port 2222 is Gitea SSH. The `tailscale0` rule (`sudo ufw allow in on tailscale0`) is only needed once the Private tier transport is installed - see section 13. Drop the rules for services you do not run.

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

## 11. Recovering A Wedged Stack

If a start fails hard, `podman ps -a` can show containers stuck in `Stopping`.
That happens when the unit's cgroup was killed while containers were still
running, taking each container's `conmon` monitor with it, so Podman can no
longer reap them.

Force-remove the LocalCloud containers by name - never `podman rm -f -a`, which
would also destroy unrelated containers on the host:

```sh
systemctl --user stop localcloud.service
systemctl --user reset-failed localcloud.service
podman rm -f cloudflared glances gitea n8n adguard backup \
             mattermost mattermost-postgres mattermost-postgres-dump
```

Anything still listed by `podman ps -a --filter status=stopping` needs Podman's
cleanup handler run by hand before it can be removed:

```sh
podman container cleanup --rm <name>
```

`cleanup` runs the teardown the dead `conmon` never finished, and `--rm` removes
the container once that succeeds. If it still refuses, an orphaned helper process
may be holding the container; find and kill it, then retry:

```sh
pgrep -af 'conmon|rootlessport|catatonit'
kill -9 <pid>
podman rm -f <name>
```

When every removal path still reports `container state improper`, the state is
stuck in Podman's database: Podman is waiting for an exit notification from a
`conmon` that no longer exists. Podman stores container state together with the
boot ID and refreshes all of it when the boot ID changes, so **a reboot is the
supported way out**, not a workaround. `podman system migrate` triggers the same
refresh without rebooting, but it stops every container this user owns - so on a
host running unrelated containers it costs the same as a reboot with less
certainty.

Pull the latest checkout before rebooting, because lingering starts the service
again at boot, and re-run `./install.sh` afterwards: the ownership mapping and
the image pre-pull only happen in the installer, not in the unit.

Then clear the leftover pod and networks and re-run the installer:

```sh
podman pod ps
podman pod rm -f <pod-id>
podman network rm homelab_edge-net homelab_dns-net homelab_mgmt-net homelab_db-net
./install.sh
```

No data is at risk during any of this: all persistent state lives under `./data`.

### Containers Stuck In `starting` Health

Podman implements container healthchecks as systemd **user timers**. When it
cannot reach the user systemd manager - the symptom is
`dial unix /run/user/1000/systemd/private: connect: connection refused`, usually
a missing user DBus session - the timer is never created, the health state stays
`starting` indefinitely, and anything gated on it waits forever.

Confirm with:

```sh
podman inspect <container> --format '{{.State.Health.Status}}'
podman inspect <container> --format '{{json .State.Health.Log}}'
systemctl --user list-timers --all | grep -i health
```

An empty `Health.Log` plus no healthcheck timer means the timer never ran; the
service itself is probably fine. Nudge it once by hand:

```sh
podman healthcheck run <container>
```

Install `dbus-user-session` (see section 1) and log out and back in to fix the
cause. The stack itself no longer gates startup on health state, so a missing
timer costs visibility, not availability.

## 12. Power Loss And Unattended Restart

What comes back on its own after the machine loses power:

| Component | Mechanism |
|---|---|
| the stack | `loginctl enable-linger` plus the enabled `localcloud.service` (`WantedBy=default.target`) |
| individual containers | `restart: unless-stopped` in `docker-compose.yml` |
| rootless Podman socket | `systemctl --user enable podman.socket` |
| AdGuard host resolver | `/etc/resolv.conf` is a plain file and `/etc/sysctl.d/99-localcloud-rootless-ports.conf` persists |
| host DNS if AdGuard is down | `/etc/resolv.conf` points at 1.1.1.1, not at AdGuard, so the host still resolves |
| Tailscale | `tailscaled` is a system unit; confirm with `systemctl is-enabled tailscaled` |

What does **not** come back on its own:

- **The LUKS backup disk.** `cryptsetup open` and `mount` are manual, so after an
  outage `${BACKUP_DEST_PATH}` is unmounted, the volume marker is missing, and
  every nightly backup aborts until someone unlocks it by hand. Decide
  deliberately between an unattended unlock and a manual one - see below.

Verify after any outage:

```sh
systemctl --user status localcloud.service --no-pager
podman ps --format "table {{.Names}}\t{{.Status}}"
mountpoint -q /mnt/usb-disk && echo "backup disk mounted" || echo "BACKUP DISK NOT MOUNTED"
systemctl is-enabled tailscaled
podman logs backup 2>&1 | tail -20
```

The last command matters: `backup.sh` writes its aborts to the container's
stdout, so a stack whose backups have been failing every night says so there.

### Remounting The Backup Disk

```sh
sudo cryptsetup open /dev/sdX1 localcloud-backup
sudo mount /dev/mapper/localcloud-backup /mnt/usb-disk
mountpoint -q /mnt/usb-disk && ls -l /mnt/usb-disk/.localcloud-backup-volume
```

**Restart the backup container afterwards.** Podman resolves a bind mount when
the container is created, and the mount namespace does not follow a host mount
that appears later. A backup container started while the disk was still locked
keeps looking at the empty placeholder directory, so its marker check keeps
failing even though the disk is now mounted:

```sh
podman restart backup
podman exec backup /usr/local/bin/backup.sh
podman logs backup 2>&1 | tail -20
```

The forced run confirms the restic repository is reachable again. Expect
`Backup finished OK.` on the last line.

### Boot-Time Mounting

`./backup-automount.sh` makes the backup disk mount itself at boot, so the
nightly backup survives a power cut with nobody present. It handles both shapes
of backup disk: a LUKS-encrypted one (keyfile, `crypttab`, `fstab`) and a plain
filesystem (`fstab` only). Check which you have with `lsblk -f`: `FSTYPE`
reads `crypto_LUKS` for an encrypted partition, or the filesystem itself
(`ext4`, …) for a plain one.

```sh
lsblk -f
./backup-automount.sh --device /dev/sdc1
```

`--device` also accepts a path where the disk is already mounted
(`/mnt/usb-disk`) and resolves it to the underlying partition.

Either way the `fstab` entry is keyed by UUID rather than `/dev/sdX`, because
device names are assigned in probe order and can move between boots.

#### Plain, Unencrypted Backup Disk

Only the `fstab` entry is written. Snapshots are still encrypted at rest by
restic under `RESTIC_PASSWORD`, so an unencrypted disk does not mean unencrypted
backups - disk encryption is a second layer, not the only one. What it adds is
protection for the disk itself when it leaves your control.

#### LUKS-Encrypted Backup Disk

`install.sh` never calls it: editing `/etc/fstab` and adding a LUKS key slot are
host-level changes that stay an explicit decision.

**The trade.** The keyfile lives on the host root disk. The backup disk stays
protected if it is lost, sold, returned under warranty, or stolen on its own,
and stops protecting anything once the whole machine is taken, because the key
travels with it. Choose this when the server sits somewhere physically
controlled and the realistic risk is the disk leaving the building alone. Keep
the manual unlock when the machine itself could walk. Encrypting the host root
disk as well restores most of that protection, since the keyfile is then only
readable on a booted, unlocked system.

Pass the encrypted partition, not the `/dev/mapper/...` name.

What it does, in order:

1. Creates `/etc/localcloud-backup.key` from `/dev/urandom`, root-owned and
   mode `400`. An existing keyfile is reused.
2. Backs up the LUKS header to your home directory **before** touching it. Copy
   that file off the machine: a damaged header makes every snapshot
   unrecoverable regardless of passwords.
3. Adds the keyfile as an **additional** key slot, prompting for your existing
   passphrase. The passphrase is kept - it is the recovery path if the keyfile
   is lost or the root filesystem is rebuilt. The step is skipped when the
   keyfile already opens the device, so re-running is safe.
4. Adds a `/etc/crypttab` entry keyed by UUID, so a renamed device cannot point
   at the wrong disk.
5. Adds an `/etc/fstab` entry with the detected filesystem type.
6. Tests the unlock and mount path, unless the disk is already mounted.

Both table entries use `nofail`, and the `fstab` entry adds
`x-systemd.device-timeout=30`. That is not optional: without it a disk that is
absent, dead, or unplugged blocks boot on a machine you may only reach over the
network - trading a stopped backup for an unreachable server.

#### Verify With A Real Reboot

The script's own test does not exercise boot ordering:

```sh
sudo reboot
```

then:

```sh
mountpoint -q /mnt/usb-disk && echo "auto-mount works"
podman logs backup 2>&1 | tail -20
```

The mount happens in early boot, before the lingering user session starts the
stack, so the backup container sees the real disk - no `podman restart backup`
needed, unlike the manual remount above.

#### Rollback

```sh
./backup-automount.sh --device /dev/sdc1 --rollback
```

That removes the `fstab` entry, and for a LUKS disk also the `crypttab` entry,
the key slot, and the keyfile. It keeps the key slot if the device has fewer
than two enabled slots, so it cannot lock you out. For a LUKS disk, confirm your passphrase still works afterwards:

```sh
sudo cryptsetup open /dev/sdX1 localcloud-backup
```

**Unchanged either way.** `RESTIC_PASSWORD` and `N8N_ENCRYPTION_KEY` still must
live off the backup disk. Disk encryption protects the disk at rest; it is not
what makes the snapshots encrypted, and it is not a substitute for keeping those
secrets somewhere else.

## 13. Private Tier (Tailscale)

Optional. Enables the Private (Tier B) exposure tier - see [SECURITY.md](SECURITY.md) for the policy and [docs/tailscale.md](docs/tailscale.md) for the design.

1. Install and authenticate on the host:

   ```sh
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```

   Use an SSO account protected by MFA. In the admin console: least-privilege ACLs, key expiry disabled for this server node only, MagicDNS on, "Override local DNS" OFF for this server (the `dns` profile owns `/etc/resolv.conf`). No subnet routing.

   Example least-privilege ACL in the current `grants` syntax. Two syntax notes from real installs: the `ip` field takes **plain port numbers** (`"22"`, not `"22/tcp"` or `"tcp/22"`), and device hostnames are not valid rule subjects - alias them through `hosts` with their tailnet IPs (`tailscale status` lists them):

   ```json
   {
       "hosts": {
           "server-alias": "100.x.y.z/32",
           "laptop-alias": "100.a.b.c/32"
       },
       "grants": [
           {"src": ["laptop-alias"], "dst": ["server-alias"], "ip": ["22"]}
       ],
       "tests": [
           {"src": "100.a.b.c", "accept": ["server-alias:22"], "deny": ["server-alias:3001"]}
       ]
   }
   ```

   Plain `ping` (ICMP) is blocked by this rule set on purpose - use `tailscale ping <server>` to verify the WireGuard path instead.

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
