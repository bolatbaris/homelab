#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_NAME="localcloud"
SERVICE_NAME="${PROJECT_NAME}.service"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

env_value() {
  local key="$1"
  local value
  value="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- || true)"
  value="${value%%[[:space:]]#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_env_value() {
  local key="$1"
  local value
  value="$(env_value "$key")"
  if [ -z "$value" ] || printf '%s' "$value" | grep -Eq '^(change-me|your-|example-|localcloud\.example$)'; then
    fail ".env must set a real value for ${key}"
  fi
}

info "LocalCloud Stack installer"
cd "$REPO_DIR"

if [ -f docker-compose.override.yml ]; then
  fail "docker-compose.override.yml is auto-loaded by Compose and can expose dev ports. Remove it and use compose.dev.yml explicitly for development."
fi

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  cat <<'MSG'
Created .env from .env.example.
Edit .env with real values, then run ./install.sh again.

Required minimum:
  TUNNEL_TOKEN
  LAN_IP
  BASE_DOMAIN
  N8N_ENCRYPTION_KEY
  RESTIC_PASSWORD
  BACKUP_DEST_PATH
  PODMAN_SOCKET_PATH if enabling the mgmt profile
MSG
  exit 0
fi

chmod 600 .env

require_command podman
require_command podman-compose
require_command loginctl
require_command systemctl
require_command mountpoint

for key in \
  TUNNEL_TOKEN LAN_IP BACKUP_DEST_PATH RESTIC_PASSWORD BASE_DOMAIN \
  MONITOR_SUBDOMAIN GITEA_SUBDOMAIN N8N_SUBDOMAIN N8N_ENCRYPTION_KEY
do
  require_env_value "$key"
done

LAN_IP="$(env_value LAN_IP)"
BACKUP_DEST_PATH="$(env_value BACKUP_DEST_PATH)"
BACKUP_REQUIRE_MOUNT="$(env_value BACKUP_REQUIRE_MOUNT)"
PODMAN_COMPOSE_BIN="$(command -v podman-compose)"

info "Creating private data directories"
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf} \
         ./data/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes,postgres}
chmod -R go-rwx ./data

info "Fixing rootless Podman bind-mount ownership"
podman unshare chown -R 1000:1000 ./data/n8n
podman unshare chown -R 2000:2000 \
  ./data/mattermost/config ./data/mattermost/data ./data/mattermost/logs \
  ./data/mattermost/plugins ./data/mattermost/client-plugins ./data/mattermost/bleve-indexes

info "Preparing Ubuntu resolver and low-port binding for AdGuard DNS"
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/localcloud-no-stub.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=no
EOF
sudo systemctl restart systemd-resolved

sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null

echo "net.ipv4.ip_unprivileged_port_start=53" | sudo tee /etc/sysctl.d/99-localcloud-rootless-ports.conf >/dev/null
sudo sysctl --system >/dev/null

if [ "$BACKUP_REQUIRE_MOUNT" = "true" ] && ! mountpoint -q "$BACKUP_DEST_PATH"; then
  warn "$BACKUP_DEST_PATH is not mounted. Backup container will start, but scheduled backups will abort until the mount exists."
fi

info "Enabling rootless Podman socket and user service"
loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
mkdir -p ~/.config/systemd/user
cat > "$HOME/.config/systemd/user/$SERVICE_NAME" <<EOF
[Unit]
Description=LocalCloud Stack
After=network-online.target podman.socket
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$REPO_DIR
ExecStart=$PODMAN_COMPOSE_BIN -f $COMPOSE_FILE up -d
ExecStop=$PODMAN_COMPOSE_BIN -f $COMPOSE_FILE down
Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"

info "Starting base stack"
"$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" up -d

info "Done"
printf 'Check status with:\n  systemctl --user status %s\n  podman-compose -f docker-compose.yml ps\n' "$SERVICE_NAME"
