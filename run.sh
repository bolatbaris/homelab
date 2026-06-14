#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/7] Creating data directories..."
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf}

echo "==> [2/7] Fixing n8n data dir ownership for rootless Podman uid mapping..."
# n8n image runs as uid 1000 (node); host-created dir is owned by the host
# user's mapped uid, not 1000 inside the user namespace. Without this,
# n8n hits EACCES on ./data/n8n and crash-loops on first boot.
podman unshare chown -R 1000:1000 ./data/n8n

echo "==> [3/7] Disabling systemd-resolved stub listener (frees port 53 for AdGuard)..."
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/adguard-no-stub.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF
sudo systemctl restart systemd-resolved

echo "==> [4/7] Repointing /etc/resolv.conf to 1.1.1.1 (temporary upstream until AdGuard takes over)..."
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null

echo "==> [5/7] Allowing rootless Podman to bind port 53..."
echo "net.ipv4.ip_unprivileged_port_start=53" | sudo tee /etc/sysctl.d/99-rootless-ports.conf >/dev/null
sudo sysctl --system

echo "==> [6/7] Enabling linger + podman services for autonomous boot..."
loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
systemctl --user enable --now podman-restart.service

echo "==> [7/7] Starting the stack..."
podman-compose up -d

echo "==> Done. Run 'podman-compose ps' to check status."
