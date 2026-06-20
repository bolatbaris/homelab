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

# True when LOCALCLOUD_PROFILES (comma-separated) contains the given profile.
profile_enabled() {
  case ",${LOCALCLOUD_PROFILES}," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
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

Optional services via LOCALCLOUD_PROFILES (comma-separated):
  dns  -> AdGuard Home (the installer will reconfigure the host resolver)
  mgmt -> Portainer (requires PODMAN_SOCKET_PATH)
  chat -> Mattermost + PostgreSQL (requires MATTERMOST_DB_PASSWORD)
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
LOCALCLOUD_PROFILES="$(env_value LOCALCLOUD_PROFILES)"
PODMAN_COMPOSE_BIN="$(command -v podman-compose)"

# Translate LOCALCLOUD_PROFILES (e.g. "dns,chat") into repeated --profile flags.
PROFILE_ARGS=""
for p in $(printf '%s' "$LOCALCLOUD_PROFILES" | tr ',' ' '); do
  [ -n "$p" ] && PROFILE_ARGS="$PROFILE_ARGS --profile $p"
done

# Per-profile required configuration.
if profile_enabled mgmt; then require_env_value PODMAN_SOCKET_PATH; fi
if profile_enabled chat; then require_env_value MATTERMOST_DB_PASSWORD; fi

info "Creating private data directories"
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf} \
         ./data/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes,postgres}
chmod -R go-rwx ./data

info "Fixing rootless Podman bind-mount ownership"
podman unshare chown -R 1000:1000 ./data/n8n
podman unshare chown -R 2000:2000 \
  ./data/mattermost/config ./data/mattermost/data ./data/mattermost/logs \
  ./data/mattermost/plugins ./data/mattermost/client-plugins ./data/mattermost/bleve-indexes

# AdGuard DNS is opt-in. Only reconfigure the host resolver when the dns profile
# is enabled -- these changes are destructive on hosts that manage
# /etc/resolv.conf via netplan or NetworkManager, so never do them unasked.
if profile_enabled dns; then
  info "AdGuard DNS profile enabled -- reconfiguring host resolver"
  info "  (disables systemd-resolved stub, repoints /etc/resolv.conf to 1.1.1.1, allows rootless port 53)"
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
else
  info "AdGuard DNS profile not enabled -- leaving the host resolver untouched"
fi

# Backup volume marker: the backup container checks for this file to confirm the
# real disk is mounted (a bind-mount alone always looks like a mount point).
if mountpoint -q "$BACKUP_DEST_PATH"; then
  touch "$BACKUP_DEST_PATH/.localcloud-backup-volume"
  info "Backup volume mounted; marker present at $BACKUP_DEST_PATH/.localcloud-backup-volume"
elif [ "$BACKUP_REQUIRE_MOUNT" = "true" ]; then
  warn "$BACKUP_DEST_PATH is not mounted. Mount it and create $BACKUP_DEST_PATH/.localcloud-backup-volume,"
  warn "or scheduled backups will abort (by design) to avoid writing onto the host disk."
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
ExecStart=$PODMAN_COMPOSE_BIN -f $COMPOSE_FILE$PROFILE_ARGS up -d
ExecStop=$PODMAN_COMPOSE_BIN -f $COMPOSE_FILE down
Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"

info "Starting stack"
# shellcheck disable=SC2086
"$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" $PROFILE_ARGS up -d

info "Done"
printf 'Check status with:\n  systemctl --user status %s\n  podman-compose -f docker-compose.yml ps\n' "$SERVICE_NAME"
