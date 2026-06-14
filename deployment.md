# Deployment Runbook — Production (Debian, Rootless Podman)

Strict copy-paste guide for first-time bring-up on the 2013 Debian box.
Run all commands as the **non-root user** that will own the rootless Podman containers (referred to below as `<user>`, uid 1000 assumed).

---

## AdGuard Host Prerequisites

These steps must be done before running `podman-compose up` for the first time on a host that will run AdGuard.

### A. Static IP via netplan
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

### B. Allow rootless Podman to bind port 53
Port 53 is privileged (<1024). Create `/etc/sysctl.d/99-unprivileged-port.conf`:
```
net.ipv4.ip_unprivileged_port_start=53
```
Apply: `sudo sysctl --system`

### C. Disable systemd-resolved stub listener
Ubuntu's `systemd-resolved` binds `127.0.0.53:53` by default. Disable it:

Edit `/etc/systemd/resolved.conf`:
```ini
[Resolve]
DNSStubListener=no
```
Then:
```sh
sudo systemctl restart systemd-resolved
sudo rm /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
```
(Run the `resolv.conf` step after AdGuard is up and serving DNS.)

---

## 1. Transfer the repo to the server

**Option A — git clone (preferred, repo has a remote):**
```sh
git clone <repo-url> ~/homelab
cd ~/homelab
```
`.gitignore` already excludes `.env`, `data/`, `mock-usb/` — clone brings only tracked config (compose files, `backup/`, docs, `.env.example`). No secrets/dev data leak across.

**Option B — no remote yet, copy from Mac via rsync:**
```sh
# run from the Mac
rsync -avz --exclude='.env' --exclude='data/' --exclude='mock-usb/' \
  ~/Desktop/repos/homelab/ <user>@<server-ip>:~/homelab/
```

---

## 2. Verify rootless Podman + enable user socket
```sh
podman --version
systemctl --user enable --now podman.socket
systemctl --user status podman.socket   # confirm "active (listening)"
```
This is what `PODMAN_SOCKET_PATH=/run/user/1000/podman/podman.sock` (next step) connects Portainer to.

---

## 3. Configure `.env`
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

## 4. Pre-create data directories (avoids uid-1000 `EACCES`)
```sh
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/conf,adguard/work}
```

---

## 5. Hardware sensors (for Glances temps)
```sh
sudo apt update && sudo apt install -y lm-sensors
sudo sensors-detect   # answer YES to load detected modules now + on boot
sudo modprobe coretemp
sensors   # sanity check — should print temps
```
If `sensors` prints nothing, `/sys/class/hwmon` will be empty regardless of container mounts — fix this before proceeding, Glances can't conjure data that isn't there.

---

## 6. Enforce zero-ports — remove dev override
```sh
rm -f docker-compose.override.yml
```
Confirm it's gone — its presence would map `9000/61208/3000/5678` onto the host, breaking the "Cloudflare tunnel only" principle. Base `docker-compose.yml` keeps only: `2222:22` (Gitea SSH), `53:53` TCP/UDP (AdGuard DNS), and `3001:3000` (AdGuard web UI, LAN-only) — all documented exceptions in architecture.md.

---

## 7. USB backup mount sanity check
```sh
mount | grep usb-disk   # confirm /mnt/usb-disk is mounted
ls /mnt/usb-disk         # should be writable by <user>
```
If not mounted yet, mount/fstab-entry the USB drive before first `up` — `backup` container will still start, but won't have anything to write to until this is correct.

---

## 8. Bring up the stack
```sh
podman-compose up -d
podman-compose ps
podman-compose logs -f --tail=50
```

---

## 9. Verify
- `systemctl --user status podman.socket` — active
- `podman-compose ps` — all 6 containers `Up`
- Cloudflare Zero Trust dashboard → tunnel shows "Healthy"
- Visit `https://portainer.localcloud.example`, `https://monitor.localcloud.example`, `https://git.localcloud.example`, `https://n8n.localcloud.example` — all reachable
- `sensors` output matches what Glances shows in its temperature panel
- `git@localcloud.example:2222` SSH clone works (after DNS A record + router forward `2222→2222`, per architecture.md Phase 5)
- `dig @192.168.1.10 example.com` (or `dig @127.0.0.1 example.com` on the host itself) — should return a valid A record, confirming AdGuard is serving DNS
- Visit `http://192.168.1.10:3001` — AdGuard web UI reachable on LAN (or `http://localhost:3001` in dev)

---

## 10. Boot persistence (optional, do after stack is confirmed stable)
Podman has no background daemon like Docker Desktop — `restart: unless-stopped` only takes effect while `podman-compose` itself keeps running. For survival across reboots:
```sh
podman generate systemd --new --files --name <container>
```
for each container, then `systemctl --user enable --now <unit>`. Revisit once the stack is stable — not required for initial bring-up.
