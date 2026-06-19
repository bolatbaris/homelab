# Deployment Runbook — Production (Debian, Rootless Podman)

Strict copy-paste guide for first-time bring-up on the 2013 Debian box.
Run all commands as the **non-root user** that will own the rootless Podman containers (referred to below as `<user>`, uid 1000 assumed).

---

## 1. Transfer the repo to the server

**Option A — git clone (preferred, repo has a remote):**
```sh
git clone <repo-url> ~/homelab
cd ~/homelab
```
`.gitignore` already excludes `.env`, `data/`, `mock-usb/` — clone brings only tracked config (compose files, `backup/`, docs, `.env.example`, `run.sh`). No secrets/dev data leak across.

**Option B — no remote yet, copy from Mac via rsync:**
```sh
# run from the Mac
rsync -avz --exclude='.env' --exclude='data/' --exclude='mock-usb/' \
  ~/Desktop/repos/homelab/ <user>@<server-ip>:~/homelab/
```

---

## 2. Configure `.env`
```sh
cd ~/homelab
cp .env.example .env
nano .env   # or vim
```
Edit:
- `TUNNEL_TOKEN=` → real Cloudflare Tunnel token
- `BACKUP_DEST_PATH=./mock-usb` → `BACKUP_DEST_PATH=/mnt/usb-disk`
- `PODMAN_SOCKET_PATH=/var/folders/.../podman-machine-default-api.sock` → comment out, uncomment/use:
  ```
  PODMAN_SOCKET_PATH=/run/user/1000/podman/podman.sock
  ```
- `BASE_DOMAIN` / `*_SUBDOMAIN` vars — leave as-is unless domains changed
- `MATTERMOST_DB_PASSWORD=` → set a long random value (`openssl rand -hex 32`); used by the Mattermost app + its internal-only PostgreSQL container

---

## 3. Static IP via netplan (AdGuard prerequisite)
AdGuard is pointed at by every LAN device as their DNS server — it must always be at the same address. Configure a static IP in netplan:

Edit `/etc/netplan/01-netcfg.yaml` (replace `<iface>` with the actual interface name from `ip link`, e.g. `eth0` or `enp3s0`; replace `<gateway-ip>` with your router's IP, typically `192.168.1.1`):

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
          via: <gateway-ip>
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

Apply: `sudo netplan apply`
Also reserve/exclude `192.168.1.10` from the modem's DHCP lease pool.

---

## 4. Hardware sensors (for Glances temps)
```sh
sudo apt update && sudo apt install -y lm-sensors
sudo sensors-detect   # answer YES to load detected modules now + on boot
sudo modprobe coretemp
sensors   # sanity check — should print temps
```
If `sensors` prints nothing, `/sys/class/hwmon` will be empty regardless of container mounts — fix this before proceeding, Glances can't conjure data that isn't there.

---

## 5. Enforce zero-ports — remove dev override
```sh
rm -f docker-compose.override.yml
```
Confirm it's gone — its presence would map `9000/61208/3000/5678` onto the host, breaking the "Cloudflare tunnel only" principle. Base `docker-compose.yml` keeps only: `2222:22` (Gitea SSH), `53:53` TCP/UDP (AdGuard DNS), and `3001:3000` (AdGuard web UI, LAN-only) — all documented exceptions in architecture.md.

---

## 6. USB backup mount sanity check
```sh
mount | grep usb-disk   # confirm /mnt/usb-disk is mounted
ls /mnt/usb-disk         # should be writable by <user>
```
If not mounted yet, mount/fstab-entry the USB drive before first `up` — `backup` container will still start, but won't have anything to write to until this is correct.

---

## 7. Run the deployment script
```sh
chmod +x run.sh
./run.sh
```
This single step consolidates everything that used to be manual: pre-creates `./data/*` directories (avoids uid-1000 `EACCES`), fixes `./data/n8n` ownership to uid 1000 via `podman unshare chown` (prevents an n8n crash loop under rootless Podman's uid mapping), clears port 53 for AdGuard (disables `systemd-resolved`'s stub listener, repoints `/etc/resolv.conf`), persists the rootless-Podman unprivileged-port sysctl, enables `loginctl linger` + `podman.socket` + `homelab.service` for autonomous boot, checks whether `/mnt/usb-disk` is mounted (warns but doesn't block if not — see Phase 9), and finally runs `podman-compose up -d`.

---

## 8. Verify
- `systemctl --user status podman.socket` and `homelab.service` — both active/enabled
- `podman-compose ps` — all 9 containers `Up` (includes `mattermost` + `mattermost-postgres`)
- Cloudflare Zero Trust dashboard → tunnel shows "Healthy"
- Visit `https://portainer.localcloud.example`, `https://monitor.localcloud.example`, `https://git.localcloud.example`, `https://n8n.localcloud.example`, `https://mattermost.localcloud.example` — all reachable
- `sensors` output matches what Glances shows in its temperature panel
- `git@localcloud.example:2222` SSH clone works (after DNS A record + router forward `2222→2222`, per architecture.md Phase 5)
- `dig @192.168.1.10 example.com` (or `dig @127.0.0.1 example.com` on the host itself) — should return a valid A record, confirming AdGuard is serving DNS
- Visit `http://192.168.1.10:3001` — AdGuard web UI reachable on LAN
- `podman port mattermost-postgres` returns nothing — confirms the database has no host port (internal-only, as intended)

---

## Troubleshooting

### 502 on all tunnel hostnames
Check that AdGuard is not bound to `0.0.0.0:53`; it must be `<LAN_IP>:53` (e.g. `192.168.1.10:53`) so `aardvark-dns` owns the bridge gateway (`10.89.0.1:53`) for container-name resolution. If AdGuard captures `10.89.0.1:53`, `cloudflared` can't resolve container-name origins (`http://portainer:9000`) and every public hostname returns 502.

Diagnose:
```sh
sudo ss -tulpn | grep ':53'
# AdGuard should show 192.168.1.10:53, not *:53 / 0.0.0.0:53

podman run --rm --net homelab_homelab-net alpine nslookup portainer 10.89.0.1
# must resolve to portainer's container IP, not NXDOMAIN
```
Fix: ensure `docker-compose.yml`'s `adguard` service maps `"192.168.1.10:53:53/tcp"` and `"192.168.1.10:53:53/udp"` (not `"53:53"`), then restart the stack. See architecture.md Phase 7 "DNS Port Binding" for full rationale.

---

## Phase 9: Persistent Backup Storage (USB)

This section hardens the USB backup drive mount before `run.sh`/`podman-compose up` — do this once, before step 7, on first bring-up (or whenever the drive is replaced).

### 1. Identify the partition
```sh
lsblk -f
```
Note the `UUID`, `FSTYPE`, and `LABEL` of the target USB partition. Check carefully — the next step is destructive if pointed at the wrong device.

### 2. Format a fresh drive (skip if already `ext4` with data you want to keep)
```sh
sudo mkfs.ext4 -L homelab-backup /dev/sdX1   # replace /dev/sdX1 with the actual partition
```
**This destroys all existing data on the partition.** `ext4` is required (not optional) — `backup.sh`'s `rsync -aAXH` flags (Phase 2) preserve ACLs (`-A`) and extended attributes (`-X`), which FAT32/exFAT don't support; using either would silently drop those attributes on every backup and break the "drop-in restore, zero permission errors" guarantee. The `-L homelab-backup` label makes the drive identifiable later via `lsblk -f`'s `LABEL` column — important once multiple USB devices are in play, to avoid formatting the wrong one next time.

### 3. Create the mount point
```sh
sudo mkdir -p /mnt/usb-disk
```

### 4. Add persistent fstab entry
Edit `/etc/fstab`, add (replace `<uuid>` from step 1; filesystem is `ext4`):
```
UUID=<uuid> /mnt/usb-disk ext4 defaults,nofail,x-systemd.automount 0 2
```
- `nofail` — boot doesn't hang/fail if the drive is unplugged; without this, a missing USB can prevent the *entire* stack (including AdGuard DNS) from starting.
- `x-systemd.automount` — systemd mounts on first access rather than at boot. Combined with `nofail`, a missing drive is skipped silently at boot — the `backup.sh` mount guard (below) is what actually catches it, at the time it matters.
- No `uid=`/`gid=` — these are vfat/exfat/ntfs-3g mount options. `ext4` stores ownership in its inodes, not as a mount-time mapping; set ownership via `chown` (next step) instead.

### 5. Mount and set ownership
```sh
sudo mount -a
sudo chown -R 1000:1000 /mnt/usb-disk
df -h                  # confirm /mnt/usb-disk, expected size
ls -la /mnt/usb-disk   # confirm owned by uid 1000
```

After this, step 6's `mount | grep usb-disk` check should pass permanently across reboots.

### Mount Guard: `backup.sh` Won't Silently Write to the Host Disk
`backup/backup.sh` checks `mountpoint -q /backup` before running `rsync`, gated by `BACKUP_REQUIRE_MOUNT` (set in `.env`):
- **`BACKUP_REQUIRE_MOUNT=true`** (prod, set this in `.env`) — if `/mnt/usb-disk` isn't actually mounted, the backup run logs an error to `/var/log/backup.log` and exits, **instead of** rsyncing all service data onto the host's root filesystem. The container keeps running; the next scheduled run (03:00) retries automatically once the drive is mounted — no restart needed.
- **`BACKUP_REQUIRE_MOUNT=false`** (dev default) — guard skipped, since `./mock-usb` is intentionally a plain directory, not a mountpoint.

`run.sh` step 7 also runs a non-fatal `mountpoint -q /mnt/usb-disk` check on every bring-up and prints a warning if the USB isn't mounted — the rest of the stack still starts either way.

---

## Phase 11: Mattermost (Self-Hosted Team Chat)

Mattermost adds **two** containers — the `mattermost` app server and a dedicated `mattermost-postgres` database (Mattermost requires PostgreSQL; it has no SQLite mode). Both run on `homelab-net` with **no host ports**; only the app is published, via the Cloudflare Tunnel.

### 1. Set the database password in `.env`
```sh
openssl rand -hex 32   # copy the output into MATTERMOST_DB_PASSWORD in .env
```
Use **hex**, not base64 — base64's `+` `/` `=` characters would break the `postgres://…` connection string. The same value is used by both the `mattermost` and `mattermost-postgres` containers. The database is internal-only — no host port, no tunnel hostname — so it is never reachable from the internet.

### 2. Add the Cloudflare Public Hostname (same pattern as Portainer/Gitea/n8n)
Zero Trust → Networks → Tunnels → (existing tunnel) → Public Hostname → Add:
- Subdomain `mattermost`, Domain `localcloud.example`
- Service **HTTP**, URL `mattermost:8065`

WebSockets (real-time messaging) pass through the tunnel automatically — no extra config. Do **not** add a hostname for `mattermost-postgres`.

### 3. First run — create the admin, signup stays locked
On first bring-up, visit `https://mattermost.localcloud.example`. The **first account you create becomes the system administrator.** Because `MM_TEAMSETTINGS_ENABLEOPENSERVER=false` is baked into the compose file, no one else who reaches the public URL can self-register — invite users from the System Console instead. Turn on MFA for admin accounts (System Console → Authentication → MFA).

### 4. Ownership note (rootless Podman)
`run.sh` pre-chowns the Mattermost app data dirs to uid 2000 (the image's runtime user). The `postgres` data dir is left alone — the Postgres image self-chowns it on first init. No manual action needed beyond `run.sh`.

---

## Boot Persistence (Auto-start)

### Why not `podman generate systemd`?
Per-container generated units (7 containers = 7 units to regenerate every time `docker-compose.yml` changes) and Podman Quadlets (compatibility risk on this box's older systemd/Podman, would replace the compose files entirely) were both rejected. Instead, a single committed unit, [`systemd/homelab.service`](systemd/homelab.service), runs `podman-compose up -d`/`down` for the whole stack — one file, no regeneration, covers any future service added to `docker-compose.yml` automatically. See architecture.md Phase 8 for full rationale.

### What `run.sh` sets up (once, automatically)
- **`loginctl enable-linger $USER`** — keeps the user's systemd instance (and its containers) running after logout/reboot, without requiring a login session. Without this, `homelab.service` never runs on a headless reboot.
- **`podman.socket`** — rootless Podman API socket (used by Portainer and required by `homelab.service`'s `After=podman.socket` ordering).
- **`homelab.service`** — symlinked from `systemd/homelab.service` into `~/.config/systemd/user/`, then `daemon-reload` + `enable --now`. On boot, starts the full stack via `podman-compose up -d`.

### Manual operation
Check status and logs:
```sh
systemctl --user status homelab.service
journalctl --user -u homelab.service -f
```

Stop/start the stack **through systemd** (not `podman-compose` directly), so systemd's recorded state stays consistent with reality:
```sh
systemctl --user stop homelab.service
systemctl --user start homelab.service
```

### Path verification
`systemd/homelab.service` hardcodes `ExecStart=/usr/bin/podman-compose up -d` and `WorkingDirectory=%h/homelab`. If `podman-compose` lives elsewhere, check with `which podman-compose` and update `ExecStart=`/`ExecStop=` accordingly; if the repo isn't cloned to `~/homelab`, update `WorkingDirectory=`.

### Relationship to `restart: unless-stopped`
Complementary, not redundant: `restart: unless-stopped` (in `docker-compose.yml`) handles individual container crashes while Podman is already running. `homelab.service` handles the stack-level cold start after a reboot/power loss, when no Podman process exists yet.
