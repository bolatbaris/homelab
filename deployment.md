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

Leave `RESTIC_REPOSITORY` unset. It is a path inside the backup container, where
the disk is mounted at `/backup`, so `/backup/restic-repo` is its only correct
value and `docker-compose.yml` already supplies it. Setting it to the host path
looks reasonable and fails silently: restic writes the repository into the
container's writable layer, reports healthy snapshots, and loses them on the
next recreate while the disk stays empty. `backup.sh` refuses anything outside
`/backup`.
- `N8N_ENCRYPTION_KEY=<openssl rand -hex 32>`

Enable optional services with `LOCALCLOUD_PROFILES` (comma-separated): `dns`, `mgmt`, `chat`, `env`, `db`. Invalid profile names fail the installer. Set `PODMAN_SOCKET_PATH` only for `mgmt`, and `MATTERMOST_DB_PASSWORD` plus `MATTERMOST_SUBDOMAIN` only for `chat`. The `db` profile (section 14) and the `env` profile (section 15) need `TAILSCALE_ENABLED=true` plus their own keys (`APPDB_*` / `INFISICAL_*`); the installer refuses either profile otherwise. The `analytics` profile (section 16) and the `monitoring` profile (section 17) follow the same Tier B rule (`UMAMI_*` / `GLITCHTIP_*`).

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

The port 53 and 3001 rules are only needed when the `dns` profile (AdGuard) is enabled; port 2222 is Gitea SSH. The `tailscale0` rule (`sudo ufw allow in on tailscale0`) is only needed once the Private tier transport is installed - see section 13. The `db` and `env` profiles (sections 14 and 15) need no rule beyond that one, because their services bind the tailscale0 address. Drop the rules for services you do not run.

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
- builds the local `./backup` image (a `build:` service is not rebuilt by
  `up -d`, so without this step edits under `backup/` never reach the container)
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

Gitea repositories should show an **Actions** tab - a server-side feature enabled through the compose environment, so an existing install picks it up when `podman-compose -f docker-compose.yml up -d gitea` recreates the container (Gitea's env-to-ini applies it on boot; no manual `app.ini` edit). The stack ships no runner: a runner executes workflow commands as its owning user, so deploying one - for example a repo-scoped `act_runner` in host mode - is a deliberate host-level decision ([SECURITY.md](SECURITY.md)).

Profile services appear only when enabled via `LOCALCLOUD_PROFILES`: `adguard` (`dns`), `portainer` (`mgmt`), `mattermost` + `mattermost-postgres` + `mattermost-postgres-dump` (`chat`), `infisical` + `infisical-postgres` + `infisical-redis` + `infisical-db-dump` (`env`), `appdb` + `appdb-adminer` + `appdb-dump` (`db`), `umami` + `umami-postgres` + `umami-db-dump` (`analytics`), `glitchtip` + `glitchtip-postgres` + `glitchtip-valkey` + `glitchtip-db-dump` (`monitoring`). When the `dns` profile is enabled, also verify AdGuard:

```sh
dig @"$LAN_IP" example.com
curl -I "http://$LAN_IP:${ADGUARD_WEB_PORT:-3001}"
```

Confirm the backup container is the one this checkout describes, not an older
image that happens to share its name:

```sh
podman exec backup restic version
podman exec backup sh -c 'tail -5 /backup/backup.log'
```

`restic: not found` means the image is stale and the backups being written are
whatever the previous entrypoint did. Rebuild:

```sh
podman-compose -f docker-compose.yml build --no-cache backup
podman-compose -f docker-compose.yml up -d backup
podman exec backup /usr/local/bin/backup.sh
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

Infisical (requires Tailscale - section 13 first):

```sh
podman-compose -f docker-compose.yml --profile env up -d infisical-postgres infisical-redis infisical-db-dump infisical
```

Umami (requires Tailscale - section 13 first):

```sh
podman-compose -f docker-compose.yml --profile analytics up -d umami-postgres umami-db-dump umami
```

GlitchTip (requires Tailscale - section 13 first):

```sh
podman-compose -f docker-compose.yml --profile monitoring up -d glitchtip-postgres glitchtip-valkey glitchtip-db-dump glitchtip
```

## 10. Restore

The helper restores with the correct rootless-Podman ownership and keeps your current data aside:

```sh
cd ~/localcloud-stack
./restore.sh            # latest snapshot
./restore.sh <id>       # a specific snapshot from `restic snapshots`
```

Manual equivalent - note the `podman unshare`, required so restored files get the user-namespace ownership the containers expect (a plain non-root restore cannot set those owners). Add the same `--profile ...` flags you enabled in `.env`.

`RESTIC_REPOSITORY` below is the **host** path, `${BACKUP_DEST_PATH}/restic-repo`, because restic is running on the host here. That is a different view of the same repository the backup container reaches at `/backup/restic-repo`, and it is why the variable belongs in this command rather than in `.env`.

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

Restore requires the **same** `.env` secrets as the original deployment - especially `RESTIC_PASSWORD` (to open the repo) and `N8N_ENCRYPTION_KEY` / `MATTERMOST_DB_PASSWORD` / `INFISICAL_ENCRYPTION_KEY` (to decrypt restored credentials).

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
             mattermost mattermost-postgres mattermost-postgres-dump \
             infisical infisical-postgres infisical-redis infisical-db-dump
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
podman network rm homelab_edge-net homelab_dns-net homelab_mgmt-net homelab_db-net homelab_env-net
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

   `TAILSCALE_IP` can stay empty: `./install.sh` detects the tailscale0 IPv4, validates it, and writes it back to `.env` for Tier B service binds. A pre-set `TAILSCALE_IP` must match the detected address or the installer fails. `TAILSCALE_ENABLED=true` is **required** for the `env` profile - see section 15.

4. Rerun `./install.sh`. The installer fails closed when `TAILSCALE_ENABLED=true` but the `tailscale` binary is missing or the node has no tailscale0 address.

The `db` profile (section 14) and the `env` profile (section 15) depend on this section being complete; the installer refuses either otherwise.

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

## 14. Application Database (`db` Profile)

Optional. A general-purpose PostgreSQL for your own backend applications, plus
Adminer, plus a logical-dump sidecar. This is a Private (Tier B) service: it is
reachable over Tailscale and from the `appdb-net` compose network, and it is
never published to the LAN or routed through Cloudflare Tunnel.

Separate from `mattermost-postgres` on purpose. That one stays internal to the
`chat` profile, keeps its own PostgreSQL 15 pin, and shares no data, no network,
and no restore blast radius with your application databases.

### Prerequisites

Section 13 first. The `db` profile is refused without it:

```
ERROR: LOCALCLOUD_PROFILES includes 'db', but TAILSCALE_ENABLED is not 'true'.
```

That is deliberate. Without a tailscale0 address the port mapping has nothing to
bind to and would fall back to every interface, putting the database on the LAN.

### Enable

In `.env`:

```sh
LOCALCLOUD_PROFILES=db          # or e.g. dns,chat,db
TAILSCALE_ENABLED=true

APPDB_SUPERUSER_PASSWORD=<openssl rand -hex 32>
APPDB_APP_USER=appuser
APPDB_APP_PASSWORD=<openssl rand -hex 32>
APPDB_DATABASES=app1,app2
```

Hex, not base64: `+`, `/`, and `=` break a `postgres://` connection string.

Then:

```sh
./install.sh
```

### What The First Start Creates

On a **fresh** cluster only, `db/initdb/10-appdb-seed.sh` creates the
`APPDB_APP_USER` role and one database per `APPDB_DATABASES` entry, each owned by
that role, each with `CONNECT` revoked from `PUBLIC`.

"Fresh" means `./data/appdb/postgres` is empty. This is what makes a restore win
over the seed: `./restore.sh` repopulates that directory, so the seed does not
run and cannot overwrite recovered data.

The consequences are worth stating plainly:

- **Adding a name to `APPDB_DATABASES` later does nothing.** The cluster is no
  longer empty. Create it by hand:
  ```sh
  podman exec -it appdb psql -U "$SU" -c 'CREATE DATABASE app3 OWNER appuser'
  ```
- **Changing `APPDB_APP_PASSWORD` later does not change the database.** `.env`
  seeds; it does not reconcile. Rotate both sides:
  ```sh
  podman exec -it appdb psql -U "$SU" \
    -c "ALTER ROLE appuser PASSWORD 'the-new-password'"
  # then set the same value in .env and re-run ./install.sh
  ```

Database and role names must match `^[a-z_][a-z0-9_]{0,62}$`. They become SQL
identifiers, which cannot be parameterized, so the seed rejects anything else
rather than trying to quote it, and the container refuses to start.

### Grant The Ports In Your Tailscale ACL

Binding to the tailscale0 address makes the database reachable *on* the tailnet;
it does not make it reachable *to* a device. A least-privilege ACL still has to
grant the ports, and the symptom of forgetting is a connection that times out
from a device that is otherwise on the tailnet and can SSH in fine.

In the admin console, extend the grants from section 13:

```json
"grants": [
    {"src": ["laptop-alias"], "dst": ["server-alias"], "ip": ["22"]},
    {"src": ["laptop-alias"], "dst": ["server-alias"], "ip": ["5432", "8081"]}
],
"tests": [
    {
        "src": "100.a.b.c",
        "accept": ["server-alias:22", "server-alias:5432", "server-alias:8081"],
        "deny": ["server-alias:3001"]
    }
]
```

Plain port numbers only - `"5432"`, never `"5432/tcp"`. Keeping the database
grant on its own rule means a future device can be given `5432` without also
being given the Adminer UI. The `tests` block is validated when you save, so it
becomes a regression test against someone narrowing the grant later.

Changes apply immediately; nothing needs restarting.

### Connect

From any device on your tailnet:

```sh
tailscale ip -4                 # on the server: the address the database binds
nc -vz <tailscale-ip> 5432      # port reachability, before blaming the client
psql "postgresql://appuser@<tailscale-ip>:5432/app1"
```

If `nc` fails, the ACL grant above is missing. If `nc` succeeds and `psql` does
not exist, install a client rather than changing anything on the server. ICMP is
denied by the example ACL on purpose, so verify the path with
`tailscale ping <server>` rather than `ping`.

A GUI client (DBeaver, TablePlus, DataGrip) uses the same values: host is the
server's `100.x` tailscale address, port `5432`, user `APPDB_APP_USER`, password
`APPDB_APP_PASSWORD`.

Adminer: `http://<tailscale-ip>:8081`, pre-pointed at the `appdb` server.
Adminer has no accounts of its own - the PostgreSQL credentials are the only
authentication, which is why it lives behind the tailnet.

From a container in this compose project, join `appdb-net` and use the service
name. This never touches the published port:

```yaml
    environment:
      - DATABASE_URL=postgres://appuser:${APPDB_APP_PASSWORD}@appdb:5432/app1
    networks:
      - appdb-net
```

### The Superuser Name Is Configurable

`APPDB_SUPERUSER` defaults to `postgres`, but if you set it to anything else,
that is the only superuser the cluster has - there is no `postgres` role to fall
back on, and `psql -U postgres` fails with `role "postgres" does not exist` even
though the database is healthy and the dump sidecar is connecting fine.

Every `psql` example below uses `$SU`. Set it once per shell:

```sh
SU=$(grep -E '^APPDB_SUPERUSER=' .env | cut -d= -f2-); SU=${SU:-postgres}
echo "superuser: $SU"
```

### Verify

```sh
podman ps --filter name=appdb --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
ss -tlnp | grep 5432
```

The listening address must be the `100.x` tailscale address. **If you ever see
`0.0.0.0:5432` or `*:5432`, stop and fix it** - the database is on your LAN.

Confirm the negative case too, from a LAN host that is not on the tailnet:

```sh
nc -z -w3 <server-lan-ip> 5432 && echo "EXPOSED - investigate" || echo "not reachable from LAN, correct"
```

Check the seeded databases and the dumps:

```sh
podman exec appdb psql -U "$SU" -c '\l'
podman exec appdb psql -U "$SU" -c '\du'
podman exec appdb-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/appdb/db-dumps/
```

If a database you listed in `APPDB_DATABASES` is missing, the seed rejected it -
its log says why:

```sh
podman logs appdb 2>&1 | grep -i 'appdb-seed'
```

Expect `globals-latest.sql` plus one `<database>-latest.dump` per database.

### Restore

**Normal path** - the raw data directory, via the usual helper. It restores every
service's data, keeps your current data aside, and honors the profiles in `.env`:

```sh
./restore.sh              # latest snapshot
./restore.sh <id>         # a specific snapshot from `restic snapshots`
```

**Logical path** - when the raw data directory is damaged. The raw `PGDATA` is
copied file-level while PostgreSQL may be writing, so it carries a torn-copy
risk; the logical dumps do not. Load the globals first, or the databases will
exist with nobody able to log in to them:

```sh
podman-compose -f docker-compose.yml --profile db down
podman unshare rm -rf ./data/appdb/postgres
mkdir -p ./data/appdb/postgres
podman-compose -f docker-compose.yml --profile db up -d appdb
# wait for it to accept connections
podman exec -i appdb psql -U "$SU" < ./data/appdb/db-dumps/globals-latest.sql
for db in app1 app2; do
  podman exec -i appdb psql -U "$SU" -c "CREATE DATABASE $db OWNER appuser"
  podman exec -i appdb pg_restore -U "$SU" -d "$db" \
    < "./data/appdb/db-dumps/$db-latest.dump"
done
```

Restoring the globals brings back role passwords as stored hashes, so
applications keep working with the credentials already in their configuration.

### Rollback

```sh
# in .env: remove `db` from LOCALCLOUD_PROFILES
./install.sh
```

The installer stops the profile's containers. `./data/appdb` is left in place -
delete it by hand once you are sure you want the data gone.

## 15. Env Store (Infisical)

Optional profile `env`. [Infisical](https://infisical.com) is the stack's environment/secret store: projects keep no env files of their own and pull their variables at runtime - per project and per environment (dev, test, qa, prod). It is Tier B (Private): reachable **only through Tailscale**, bound to the tailscale0 address, and deliberately never attached to the tunnel network (`env-net` only - see [SECURITY.md](SECURITY.md)).

### Prerequisites

1. Section 13 complete: Tailscale installed on the host and `TAILSCALE_ENABLED=true` in `.env`. The installer fails closed when `env` is enabled without the Private transport.
2. Keys in `.env`:

   ```
   INFISICAL_ENCRYPTION_KEY=<openssl rand -hex 16>    # encrypts every stored secret
   INFISICAL_AUTH_SECRET=<openssl rand -base64 32>    # signs session JWTs
   INFISICAL_DB_PASSWORD=<openssl rand -hex 32>       # hex: it is embedded in the postgres:// URI
   ```

   `INFISICAL_ENCRYPTION_KEY` belongs with `RESTIC_PASSWORD` and `N8N_ENCRYPTION_KEY`: keep it **off** the backup disk. A restored snapshot is unreadable without it.
3. Enable: add `env` to `LOCALCLOUD_PROFILES` and rerun `./install.sh`.

The profile brings `infisical` (bound to `${TAILSCALE_IP}:${INFISICAL_PORT:-8080}`), `infisical-postgres` (no ports), `infisical-redis` (no ports; a hard requirement of the current Infisical image, with append-only persistence), and `infisical-db-dump` (logical `pg_dump` via the shared `backup/pg-dump.sh`, at 02:15 by default - ahead of the 02:30 appdb and 02:45 Mattermost dumps and the 03:00 restic snapshot).

### First-Run Setup

1. From an enrolled device, open `http://<tailscale-ip>:8080` and create the admin account.
2. Create a project and its environments (`dev`, `test`, `qa`, `prod`).
3. Create machine identities (Service Auth) per project/environment - these client credentials are what CI and services use to pull secrets programmatically. Scope each identity to the narrowest project/environment it needs.
4. Org membership is invite-based: accounts created without an invite see nothing. Tailnet ACLs decide who can even reach the login page - grant port `8080` only to the devices that need it (see the ACL example in section 13).

### Client Usage From Dev Devices

On any enrolled device (the CLI defaults to Infisical cloud, so point it at this instance):

```sh
infisical login --domain http://<tailscale-ip>:8080
infisical run --env prod -- <your app start command>   # secrets injected at runtime
```

`INFISICAL_API_URL` (env var) or the `domain` field in `.infisical.json` (from `infisical init`) are alternatives to `--domain`. Older CLI versions ignored the flag on login - upgrade if it does not seem to stick.

### Optional HTTPS

Tailscale already encrypts the transport (WireGuard), so plain HTTP on the tailnet is the baseline. For a valid certificate and clean URLs, front the store with `tailscale serve` (see `tailscale serve --help` for your installed version's syntax), then set `INFISICAL_SITE_URL=https://infisical.<your-tailnet>.ts.net` in `.env` and rerun `./install.sh`.

### Verify

```sh
podman ps --format "table {{.Names}}\t{{.Status}}" | grep infisical
ss -tlnp | grep "${INFISICAL_PORT:-8080}"   # foreign address: the 100.x tailscale IP, never 0.0.0.0
podman logs infisical 2>&1 | tail -20
podman exec infisical-db-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/infisical/db-dumps/           # infisical-latest.dump after the first dump run
```

Negative test from a **non-tailnet** device: `curl -m 3 http://<lan-ip>:8080` must time out or refuse.

### Restore Notes

The generic `./restore.sh` flow covers `./data/infisical` automatically. The restored PostgreSQL directory is supplemented by `infisical-latest.dump` (restore with `pg_restore` against a clean `infisical-postgres` container if the raw data restore ever fails). Decryption of the stored secrets requires the same `INFISICAL_ENCRYPTION_KEY` as when they were written - that is why it lives off the backup disk.

Rollback: remove `env` from `LOCALCLOUD_PROFILES`, rerun `./install.sh`. The containers stop and `./data/infisical` stays in place.

## 16. Analytics (Umami)

Optional profile `analytics`. [Umami](https://umami.is) is the stack's privacy-first web analytics: self-hosted, no cookies, no personal data, MIT-licensed. It is Tier B (Private): reachable **only through Tailscale**, bound to the tailscale0 address, and deliberately never attached to the tunnel network (`umami-net` only - see [SECURITY.md](SECURITY.md)).

### Prerequisites

1. Section 13 complete: Tailscale installed on the host and `TAILSCALE_ENABLED=true` in `.env`. The installer fails closed when `analytics` is enabled without the Private transport.
2. Keys in `.env`:

   ```
   UMAMI_DB_PASSWORD=<openssl rand -hex 32>   # hex: it is embedded in the postgres:// URI
   UMAMI_APP_SECRET=<openssl rand -hex 32>    # signs login sessions
   UMAMI_2FA_KEY=<openssl rand -hex 32>       # 64 hex chars; encrypts TOTP secrets behind 2FA
   ```

   Keep `UMAMI_APP_SECRET` and `UMAMI_2FA_KEY` off the backup disk, with `RESTIC_PASSWORD`: losing `UMAMI_APP_SECRET` invalidates every session, losing `UMAMI_2FA_KEY` locks out every account with 2FA enabled.
3. Enable: add `analytics` to `LOCALCLOUD_PROFILES` and rerun `./install.sh`.

The profile brings `umami` (bound to `${TAILSCALE_IP}:${UMAMI_PORT:-3002}`; 3002 rather than Umami's native 3000 so the loopback dev fallback cannot collide with Gitea's dev port), `umami-postgres` (no ports; per-feature instance on `POSTGRES_IMAGE`, never shared with another profile), and `umami-db-dump` (logical `pg_dump` via the shared `backup/pg-dump.sh`, at 02:00 by default - second in the nightly sequence, after the 01:45 GlitchTip dump and ahead of the 02:15 Infisical, 02:30 appdb, and 02:45 Mattermost dumps and the 03:00 restic snapshot).

Umami applies its database schema and migrations automatically on startup, so the first start against an empty `umami-postgres` needs no manual step.

### What Tier B Means For Analytics

Umami's collect endpoint (`/api/send`) answers trackers embedded in the pages you measure. On this stack that endpoint is reachable **only from tailnet devices**, which fits measuring your own internal tools (Gitea, n8n, Mattermost, self-hosted apps). Visitors outside the tailnet cannot report events - by design. Analytics for public websites would require a deliberate Tier A exposure decision instead (see [SECURITY.md](SECURITY.md)); do not widen this profile's reach without one.

Embedded trackers on HTTPS pages need an HTTPS collect endpoint (browsers block mixed content). Front the instance with `tailscale serve` (see section 15's HTTPS note) and use the `https://...ts.net` URL as the tracker source.

### First-Run Setup

1. From an enrolled device, open `http://<tailscale-ip>:3002` and log in as `admin` / `umami` - the upstream default credentials, seeded by Umami's init migration (there is no generated password in the container log).
2. Change the admin password immediately (Umami prompts for a new one while the default is still set) and enable two-factor authentication (encrypted with `UMAMI_2FA_KEY`).
3. Add a website per site you measure, then copy the tracking snippet into those pages' `<head>`.
4. Tailnet ACLs decide who can even reach the UI - grant port `3002` only to the devices that need it (see the ACL example in section 13).

### Verify

```sh
podman ps --format "table {{.Names}}\t{{.Status}}" | grep umami
ss -tlnp | grep "${UMAMI_PORT:-3002}"   # foreign address: the 100.x tailscale IP, never 0.0.0.0
podman logs umami 2>&1 | tail -20
podman exec umami-db-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/umami/db-dumps/           # umami-latest.dump after the first dump run
curl http://<tailscale-ip>:3002/api/heartbeat   # from an enrolled device: {"status":"ok"}
```

Negative test from a **non-tailnet** device: `curl -m 3 http://<lan-ip>:3002` must time out or refuse.

### Troubleshooting: port refuses while the container says Ready

Umami's first start once crashed beside a `umami-postgres` still in its one-time `initdb` (Umami exits on an unreachable database instead of retrying, unlike Mattermost). On rootless Podman 4.9.x that crash-loop had a second-order effect: conmon's restart supervision died and the `rootlessport` publish proxy was never (re)spawned, so after a manual `podman restart umami` the container showed `Ready` in its logs while `100.x.x.x:3002` refused connections - `podman port umami` still showed the mapping, but `ss -tlnp | grep 3002` had no listener (compare 8080/8081/5432, which each have a `rootlessport` process).

`docker-compose.yml` now gates Umami's start on the database accepting TCP, which removes the crash entirely. If a wedge like this ever recurs (any Tier B port refusing while its container looks healthy), the fix is to **recreate** the container, not restart it:

```sh
podman rm -f umami
podman-compose -f docker-compose.yml --profile analytics up -d umami
```

### Restore Notes

The generic `./restore.sh` flow covers `./data/umami` automatically. The restored PostgreSQL directory is supplemented by `umami-latest.dump` (restore with `pg_restore` against a clean `umami-postgres` container if the raw data restore ever fails):

```sh
podman-compose -f docker-compose.yml --profile analytics up -d umami-postgres
# wait for it to accept connections, then:
podman exec -i umami-postgres dropdb -U umami umami
podman exec -i umami-postgres createdb -U umami umami
podman exec -i umami-postgres pg_restore -U umami -d umami < ./data/umami/db-dumps/umami-latest.dump
```

Rollback: remove `analytics` from `LOCALCLOUD_PROFILES`, rerun `./install.sh`. The containers stop and `./data/umami` stays in place.

## 17. App-Error Monitoring (GlitchTip)

Optional profile `monitoring`. [GlitchTip](https://glitchtip.com) is the stack's Sentry-compatible error monitoring: your applications report exceptions through a Sentry DSN (or OTLP) and you triage them from a web UI. It is Tier B (Private): reachable **only through Tailscale**, bound to the tailscale0 address, and deliberately never attached to the tunnel network (`glitchtip-net` only - see [SECURITY.md](SECURITY.md)).

### Prerequisites

1. Section 13 complete: Tailscale installed on the host and `TAILSCALE_ENABLED=true` in `.env`. The installer fails closed when `monitoring` is enabled without the Private transport.
2. Keys in `.env`:

   ```
   GLITCHTIP_SECRET_KEY=<openssl rand -hex 32>    # Django SECRET_KEY; signs sessions
   GLITCHTIP_DB_PASSWORD=<openssl rand -hex 32>   # hex: it is embedded in the postgres:// URI
   ```

3. Enable: add `monitoring` to `LOCALCLOUD_PROFILES` and rerun `./install.sh`.

The profile brings `glitchtip` (upstream's single-container `SERVER_ROLE=all_in_one` - web server with the background worker embedded, which fits the stack's low-idle-resource stance; bound to `${TAILSCALE_IP}:${GLITCHTIP_PORT:-8082}`, container-internal port 8000), `glitchtip-postgres` (no ports; per-feature instance on `POSTGRES_IMAGE`, never shared with another profile), `glitchtip-valkey` (no ports; upstream's recommended queue/cache store, append-only persistence), and `glitchtip-db-dump` (logical `pg_dump` via the shared `backup/pg-dump.sh`, at 01:45 by default - first in the nightly sequence, ahead of the 02:00 Umami, 02:15 Infisical, 02:30 appdb, and 02:45 Mattermost dumps and the 03:00 restic snapshot).

GlitchTip applies its database migrations automatically on startup, so the first start against an empty `glitchtip-postgres` needs no manual step. Startup is gated on PostgreSQL and Valkey accepting TCP (the image's start script would otherwise hard-exit during migrations - see the troubleshooting note in section 16 for why that matters on rootless Podman).

### What Tier B Means For Monitoring

Event ingest (`<DSN endpoint>` and the OTLP path) answers the SDKs embedded in your applications. On this stack those endpoints are reachable **only from tailnet devices and first-party containers**, which fits monitoring your own internal tools and backends (apps on the tailnet, containers joined to `glitchtip-net` via the compose network). Applications or client-side SDKs outside the tailnet cannot report events - by design. Monitoring public-facing apps' client-side errors would require a deliberate Tier A exposure decision instead (see [SECURITY.md](SECURITY.md)); do not widen this profile's reach without one.

Point your apps' Sentry SDK at the tailnet address, for example `sentry-sdk.init(dsn="http://<public-key>@<tailscale-ip>:8082/<project-id>")`.

### First-Run Setup

1. From an enrolled device, open `http://<tailscale-ip>:8082` and register the first user. `ENABLE_USER_REGISTRATION` defaults to `false`: the signup page stays open only while the user table is empty, then closes. Add later users through a superuser or organization invites.
   - Locked out anyway (or skipped signup)? Create an admin by hand:
     ```sh
     podman exec -it glitchtip ./manage.py createsuperuser
     ```
2. Create an organization and a project per application; copy the project's DSN into that app's Sentry SDK.
3. Tailnet ACLs decide who can even reach the UI - grant port `8082` only to the devices that need it (see the ACL example in section 13).
4. Optional - uptime monitors: GlitchTip can also ping your services. Targets on private/internal IPs are blocked by default (`GLITCHTIP_UPTIME_ALLOW_PRIVATE_IPS=false`, an SSRF guard); if you want uptime checks against internal services, set that variable for the `glitchtip` service deliberately.
5. Optional - alert email: mail defaults to the container log (`consolemail://`). Set `GLITCHTIP_EMAIL_URL` to an `smtp://` URL and `GLITCHTIP_DEFAULT_FROM_EMAIL` in `.env`, then rerun `./install.sh`.

### Optional HTTPS

Tailscale already encrypts the transport (WireGuard), so plain HTTP on the tailnet is the baseline. For a valid certificate and clean URLs, front the service with `tailscale serve` (see `tailscale serve --help`), then set `GLITCHTIP_DOMAIN=https://glitchtip.<your-tailnet>.ts.net` and `GLITCHTIP_CSRF_TRUSTED_ORIGINS=https://glitchtip.<your-tailnet>.ts.net` in `.env` and rerun `./install.sh`.

### Verify

```sh
podman ps --format "table {{.Names}}\t{{.Status}}" | grep glitchtip
ss -tlnp | grep "${GLITCHTIP_PORT:-8082}"   # foreign address: the 100.x tailscale IP, never 0.0.0.0
podman logs glitchtip 2>&1 | tail -20
podman exec glitchtip-db-dump /usr/local/bin/pg-dump.sh once
ls -lh ./data/glitchtip/db-dumps/           # glitchtip-latest.dump after the first dump run
curl -m 3 http://<tailscale-ip>:8082/       # from an enrolled device: the login page
```

Negative test from a **non-tailnet** device: `curl -m 3 http://<lan-ip>:8082` must time out or refuse.

### Restore Notes

The generic `./restore.sh` flow covers `./data/glitchtip` automatically. The restored PostgreSQL directory is supplemented by `glitchtip-latest.dump` (restore with `pg_restore` against a clean `glitchtip-postgres` container if the raw data restore ever fails):

```sh
podman-compose -f docker-compose.yml --profile monitoring up -d glitchtip-postgres
# wait for it to accept connections, then:
podman exec -i glitchtip-postgres dropdb -U glitchtip glitchtip
podman exec -i glitchtip-postgres createdb -U glitchtip glitchtip
podman exec -i glitchtip-postgres pg_restore -U glitchtip -d glitchtip < ./data/glitchtip/db-dumps/glitchtip-latest.dump
```

Rollback: remove `monitoring` from `LOCALCLOUD_PROFILES`, rerun `./install.sh`. The containers stop and `./data/glitchtip` stays in place.
