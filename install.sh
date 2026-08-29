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
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
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

normalize_profiles() {
  local raw="$1"
  local normalized=""
  local profile

  for profile in $(printf '%s' "$raw" | tr ',' ' '); do
    case "$profile" in
      dns|mgmt|chat|env) ;;
      *)
        fail "Invalid LOCALCLOUD_PROFILES entry '${profile}'. Use comma-separated values from: dns, mgmt, chat, env."
        ;;
    esac

    case ",$normalized," in
      *,"$profile",*) ;;
      *) normalized="${normalized:+$normalized,}$profile" ;;
    esac
  done

  printf '%s' "$normalized"
}

# podman-compose only learned the global --profile flag in 1.1.0 (Ubuntu 24.04
# ships 1.0.6). Older builds drop the unknown flag in argparse and then read the
# profile name as the subcommand, so the real failure surfaces as the confusing
# "argument command: invalid choice: 'dns'". Probe the capability rather than
# parsing version strings.
require_compose_profile_support() {
  [ -n "$LOCALCLOUD_PROFILES" ] || return 0
  if ! "$PODMAN_COMPOSE_BIN" --help 2>&1 | grep -q -- '--profile'; then
    fail "$PODMAN_COMPOSE_BIN does not support --profile, but LOCALCLOUD_PROFILES='${LOCALCLOUD_PROFILES}' is set. Upgrade to podman-compose >= 1.1.0 (for example 'pipx install podman-compose') or clear LOCALCLOUD_PROFILES in .env."
  fi
}

# True when LOCALCLOUD_PROFILES (comma-separated) contains the given profile.
profile_enabled() {
  case ",${LOCALCLOUD_PROFILES}," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate the optional Private (Tier B) transport (docs/tailscale.md). When
# enabled, the tailscale binary must be installed and the node must have a
# tailscale0 IPv4. A pre-set TAILSCALE_IP must match the detected address;
# when empty, the detected address is returned in TAILSCALE_IP.
check_tailscale() {
  case "$TAILSCALE_ENABLED" in
    ""|false) return 0 ;;
    true) ;;
    *) fail "TAILSCALE_ENABLED must be 'true' or 'false' (or empty)." ;;
  esac
  require_command tailscale
  local detected
  detected="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [ -z "$detected" ]; then
    fail "TAILSCALE_ENABLED=true but the node has no tailscale0 IPv4. Complete docs/tailscale.md Phase V1 first."
  fi
  if [ -n "$TAILSCALE_IP" ] && [ "$TAILSCALE_IP" != "$detected" ]; then
    fail "TAILSCALE_IP='$TAILSCALE_IP' does not match the detected tailscale0 address '$detected'."
  fi
  TAILSCALE_IP="$detected"
  # tailscaled is a system unit outside this installer's control, but if it is
  # not enabled at boot then remote access does not come back after a power cut
  # -- the one moment it is needed most. Warn rather than fail: the unit name
  # and state are the host's business, not the stack's.
  if ! systemctl is-enabled --quiet tailscaled 2>/dev/null; then
    info "WARNING: tailscaled is not enabled at boot. Remote access will not return after a reboot or power cut. Fix with: sudo systemctl enable --now tailscaled"
  fi
  info "Private (Tier B) transport enabled; tailscale0 address ${TAILSCALE_IP}"
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
  chat -> Mattermost + PostgreSQL (requires MATTERMOST_DB_PASSWORD and MATTERMOST_SUBDOMAIN)
  env  -> Infisical env store, Tier B only (requires TAILSCALE_ENABLED=true plus INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET, INFISICAL_DB_PASSWORD)
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

BACKUP_DEST_PATH="$(env_value BACKUP_DEST_PATH)"
BACKUP_REQUIRE_MOUNT="$(env_value BACKUP_REQUIRE_MOUNT)"
LOCALCLOUD_PROFILES="$(normalize_profiles "$(env_value LOCALCLOUD_PROFILES)")"
TAILSCALE_ENABLED="$(env_value TAILSCALE_ENABLED)"
TAILSCALE_IP="$(env_value TAILSCALE_IP)"
PODMAN_COMPOSE_BIN="$(command -v podman-compose)"

# Translate LOCALCLOUD_PROFILES (e.g. "dns,chat") into repeated --profile flags.
PROFILE_ARGS_STRING=""
PROFILE_ARGS=()
for p in $(printf '%s' "$LOCALCLOUD_PROFILES" | tr ',' ' '); do
  if [ -n "$p" ]; then
    PROFILE_ARGS_STRING="$PROFILE_ARGS_STRING --profile $p"
    PROFILE_ARGS+=(--profile "$p")
  fi
done
info "Enabled profiles: ${LOCALCLOUD_PROFILES:-none}"
require_compose_profile_support

# Per-profile required configuration.
if profile_enabled mgmt; then require_env_value PODMAN_SOCKET_PATH; fi
if profile_enabled chat; then
  require_env_value MATTERMOST_DB_PASSWORD
  require_env_value MATTERMOST_SUBDOMAIN
fi
if profile_enabled env; then
  # The env store is Tier B (Private): its only intended transport is the
  # tailnet, so enabling it without Tailscale must not silently fall back to
  # some weaker reach (the compose bind also falls back to loopback, which
  # would just make the store unusable from other devices).
  if [ "$TAILSCALE_ENABLED" != "true" ]; then
    fail "Profile 'env' (Infisical env store) is Tier B (Private) and requires TAILSCALE_ENABLED=true. Complete deployment.md section 13 first, or disable the env profile."
  fi
  require_env_value INFISICAL_DB_PASSWORD
  require_env_value INFISICAL_ENCRYPTION_KEY
  require_env_value INFISICAL_AUTH_SECRET
fi

check_tailscale

# Persist the detected tailscale0 address so Tier B service binds resolve from
# .env (podman-compose reads .env from the project directory).
if [ "$TAILSCALE_ENABLED" = "true" ]; then
  if grep -q "^TAILSCALE_IP=" .env; then
    sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=${TAILSCALE_IP}|" .env
  else
    printf '\n# tailscale0 address detected by install.sh - used by Tier B service binds.\nTAILSCALE_IP=%s\n' "$TAILSCALE_IP" >> .env
  fi
  chmod 600 .env
  info "Persisted TAILSCALE_IP=${TAILSCALE_IP} to .env"
fi

info "Creating private data directories"
mkdir -p ./data/{portainer,monitor,gitea,n8n,adguard/work,adguard/conf} \
         ./data/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes,postgres,db-dumps} \
         ./data/infisical/{postgres,db-dumps}
# Privacy boundary: ./data itself is host-user owned and 0700, so no other
# host user can traverse it. Individual top-level dirs may be owned by
# rootless Podman subuids on migrated installs - uid isolation already covers
# those, and the host cannot chmod them, so best-effort is correct here.
chmod go-rwx ./data 2>/dev/null || true
for d in ./data/*/; do chmod go-rwx "$d" 2>/dev/null || true; done

# Every ./data/<svc> is mode 0700 and owned by the host user, which inside the
# rootless user namespace reads as root:root. Containers whose process drops to
# a non-root uid therefore cannot even traverse their own data directory, so
# each one needs its uid mapped through `podman unshare chown`. Services that
# stay root inside the container (adguard, glances, portainer, backup) need
# nothing here.
info "Fixing rootless Podman bind-mount ownership"
podman unshare chown -R 1000:1000 ./data/n8n
podman unshare chown -R 1000:1000 ./data/gitea
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
  fail "$BACKUP_DEST_PATH is not mounted. Mount it before installing because BACKUP_REQUIRE_MOUNT=true."
fi

# A LUKS backup disk unlocked by hand does not come back after a power cut, and
# the nightly backup then aborts every night until someone notices. Advisory
# only: configuring boot-time unlock changes what the disk encryption protects
# against, so it stays an explicit operator decision (./backup-automount.sh).
case "$BACKUP_DEST_PATH" in
  /*)
    if ! grep -qE "[[:space:]]${BACKUP_DEST_PATH%/}[[:space:]]" /etc/fstab 2>/dev/null; then
      info "NOTE: $BACKUP_DEST_PATH is not in /etc/fstab, so it will not remount itself after a reboot or power cut, and scheduled backups will abort until it is unlocked by hand. Run ./backup-automount.sh --device <luks-partition> to make that automatic (deployment.md section 12)."
    fi
    ;;
esac

info "Enabling rootless Podman socket and user service"
loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
mkdir -p ~/.config/systemd/user
# WorkingDirectory below is deliberately unquoted: systemd does not strip quotes
# from that directive, and a leading quote makes the path non-absolute, which is
# a fatal unit-file error on systemd >= 253 ("has a bad unit file setting").
# ExecStart/ExecStop are quote-aware, so they keep their quotes and tolerate
# spaces in the checkout path.
cat > "$HOME/.config/systemd/user/$SERVICE_NAME" <<EOF
[Unit]
Description=LocalCloud Stack
After=network-online.target podman.socket
Wants=network-online.target
# Bound restart loop. A failing "up -d" that systemd keeps retrying kills the
# cgroup - conmon included - on every attempt, which wedges containers in the
# "Stopping" state that only a force-remove clears. Three attempts, then stop
# and let the operator read the logs.
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$REPO_DIR
ExecStart="$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE"$PROFILE_ARGS_STRING up -d
ExecStop="$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE"$PROFILE_ARGS_STRING down
Restart=on-failure
RestartSec=10s
TimeoutStartSec=900
# "down" stops nine containers, each with its own SIGTERM grace period. The
# default stop timeout can expire mid-teardown and SIGKILL conmon, leaving
# containers unreapable.
TimeoutStopSec=300

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"

info "Stopping any existing LocalCloud containers before applying selected profiles"
if ! "$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" --profile dns --profile mgmt --profile chat --profile env down --remove-orphans; then
  info "WARNING: pre-start cleanup exited non-zero (normal when nothing was running)."
fi

# Pull before handing over to systemd: a cold first install downloads several
# hundred MB, and the unit's TimeoutStartSec would otherwise expire mid-pull and
# SIGTERM a half-started stack.
info "Pre-pulling service images"
if ! "$PODMAN_COMPOSE_BIN" -f "$COMPOSE_FILE" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} pull; then
  info "WARNING: image pre-pull exited non-zero (the locally built backup image has nothing to pull)."
fi

# Advisory: catches unit-file regressions before the restart hides them behind
# a generic "bad unit file setting" message.
if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze --user verify "$HOME/.config/systemd/user/$SERVICE_NAME" 2>&1; then
    info "WARNING: systemd-analyze reported issues with $SERVICE_NAME (see above)."
  fi
fi

info "Starting stack through systemd user service"
if ! systemctl --user restart "$SERVICE_NAME"; then
  systemctl --user status "$SERVICE_NAME" --no-pager || true
  journalctl --user -u "$SERVICE_NAME" -n 30 --no-pager || true
  fail "Failed to start $SERVICE_NAME. Diagnostics above."
fi

if [ "$TAILSCALE_ENABLED" = "true" ]; then
  info "Tailscale Tier B transport active: confirm 'sudo ufw allow in on tailscale0' and least-privilege ACLs (docs/tailscale.md)."
fi

info "Done"
printf 'Check status with:\n  systemctl --user status %s\n  podman-compose -f docker-compose.yml%s ps\n' "$SERVICE_NAME" "$PROFILE_ARGS_STRING"
