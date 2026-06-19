#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/8] Creating data directories..."
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf} \
         ./data/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes,postgres}

echo "==> [2/8] Fixing data dir ownership for rootless Podman uid mapping (n8n=1000, mattermost=2000)..."
# n8n image runs as uid 1000 (node); mattermost as uid 2000. A host-created
# dir is owned by the host user's mapped uid, not the in-container uid —
# without this the apps hit EACCES on their data dirs and crash-loop on first
# boot. Postgres is excluded: its own entrypoint self-chowns PGDATA.
podman unshare chown -R 1000:1000 ./data/n8n
podman unshare chown -R 2000:2000 \
  ./data/mattermost/config ./data/mattermost/data ./data/mattermost/logs \
  ./data/mattermost/plugins ./data/mattermost/client-plugins ./data/mattermost/bleve-indexes

echo "==> [3/8] Disabling systemd-resolved stub listener (frees port 53 for AdGuard)..."
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/adguard-no-stub.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF
sudo systemctl restart systemd-resolved

echo "==> [4/8] Repointing /etc/resolv.conf to 1.1.1.1 (temporary upstream until AdGuard takes over)..."
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null

echo "==> [5/8] Allowing rootless Podman to bind port 53..."
echo "net.ipv4.ip_unprivileged_port_start=53" | sudo tee /etc/sysctl.d/99-rootless-ports.conf >/dev/null
sudo sysctl --system

echo "==> [6/8] Enabling linger + podman.socket + homelab.service for autonomous boot..."
loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
mkdir -p ~/.config/systemd/user
ln -sf "$(pwd)/systemd/homelab.service" ~/.config/systemd/user/homelab.service
systemctl --user daemon-reload
systemctl --user enable --now homelab.service

echo "==> [7/8] Checking USB backup mount..."
if ! mountpoint -q /mnt/usb-disk; then
  echo "WARNING: /mnt/usb-disk is not mounted. Backup will not write to USB."
  echo "Ensure fstab entry is correct and run: sudo mount -a"
  echo "Continuing stack bring-up — backup container will abort each run"
  echo "until the drive is mounted. See deployment.md Phase 9/10."
else
  echo "/mnt/usb-disk mounted OK."
fi

echo "==> [8/8] Starting the stack (homelab.service already started it; no-op if already up)..."
podman-compose up -d

echo "==> Done. Run 'podman-compose ps' to check status."
