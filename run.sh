#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/6] Creating data directories..."
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf}

echo "==> [2/6] Disabling systemd-resolved stub listener (frees port 53 for AdGuard)..."
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/adguard-no-stub.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF
sudo systemctl restart systemd-resolved

echo "==> [3/6] Repointing /etc/resolv.conf to 1.1.1.1 (temporary upstream until AdGuard takes over)..."
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null

echo "==> [4/6] Allowing rootless Podman to bind port 53..."
echo "net.ipv4.ip_unprivileged_port_start=53" | sudo tee /etc/sysctl.d/99-rootless-ports.conf >/dev/null
sudo sysctl --system

echo "==> [5/6] Enabling linger + podman services for autonomous boot..."
loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
systemctl --user enable --now podman-restart.service

echo "==> [6/6] Starting the stack..."
podman-compose up -d

echo "==> Done. Run 'podman-compose ps' to check status."
