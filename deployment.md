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
This single step consolidates everything that used to be manual: pre-creates `./data/*` directories (avoids uid-1000 `EACCES`), fixes `./data/n8n` ownership to uid 1000 via `podman unshare chown` (prevents an n8n crash loop under rootless Podman's uid mapping), clears port 53 for AdGuard (disables `systemd-resolved`'s stub listener, repoints `/etc/resolv.conf`), persists the rootless-Podman unprivileged-port sysctl, enables `loginctl linger` + `podman.socket` + `podman-restart.service` for autonomous boot, and finally runs `podman-compose up -d`.

---

## 8. Verify
- `systemctl --user status podman.socket` and `podman-restart.service` — both active/enabled
- `podman-compose ps` — all 7 containers `Up`
- Cloudflare Zero Trust dashboard → tunnel shows "Healthy"
- Visit `https://portainer.localcloud.example`, `https://monitor.localcloud.example`, `https://git.localcloud.example`, `https://n8n.localcloud.example` — all reachable
- `sensors` output matches what Glances shows in its temperature panel
- `git@localcloud.example:2222` SSH clone works (after DNS A record + router forward `2222→2222`, per architecture.md Phase 5)
- `dig @192.168.1.10 example.com` (or `dig @127.0.0.1 example.com` on the host itself) — should return a valid A record, confirming AdGuard is serving DNS
- Visit `http://192.168.1.10:3001` — AdGuard web UI reachable on LAN

---

## Phase 9: Persistent Backup Storage (USB)

This section hardens the USB backup drive mount before `run.sh`/`podman-compose up` — do this once, before step 7, on first bring-up (or whenever the drive is replaced).

### 1. Identify the partition
```sh
lsblk -f
```
Note the `UUID` and `FSTYPE` (e.g. `ext4`) of the target USB partition.

### 2. Create the mount point
```sh
sudo mkdir -p /mnt/usb-disk
```

### 3. Add persistent fstab entry
Edit `/etc/fstab`, add (replace `<uuid>` and `<fstype>` from step 1):
```
UUID=<uuid> /mnt/usb-disk <fstype> defaults,nofail,uid=1000,gid=1000 0 2
```
- `nofail` — boot doesn't hang/fail if drive is unplugged.
- `uid=1000,gid=1000` — host user (matching rootless Podman's uid mapping) owns all files, no per-restore `chown`.

### 4. Mount and verify
```sh
sudo mount -a
df -h
```
Confirm `/mnt/usb-disk` appears, mounted, with expected size.

### 5. Ownership sanity check
```sh
sudo chown -R $USER:$USER /mnt/usb-disk
```

After this, step 6's `mount | grep usb-disk` check should pass permanently across reboots.

---

## Why no `podman generate systemd`?
Earlier drafts of this runbook generated a separate systemd unit per container. That's now replaced by two host-level primitives, set up once by `run.sh`:
- **`loginctl enable-linger $USER`** — keeps the user's systemd instance (and its containers) running after logout/reboot, without requiring a login session.
- **`podman-restart.service`** (a `--user` unit shipped with Podman) — on boot, restarts every container whose compose `restart:` policy says so (`unless-stopped`, used by every service in `docker-compose.yml`).

One enable-once host service covers all current and future containers — no per-container unit files to generate, track, or regenerate when the compose file changes.
