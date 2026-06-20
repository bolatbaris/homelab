#!/usr/bin/env bash
# Restore all service data from the encrypted restic backup, then bring the
# stack up. Reversible: each current ./data/<svc> is moved aside (not deleted).
#
# Restore REQUIRES the same .env secrets as when the backup was taken --
# especially RESTIC_PASSWORD (to open the repo) and N8N_ENCRYPTION_KEY /
# MATTERMOST_DB_PASSWORD (to decrypt restored credentials). Without them the
# data is unrecoverable even though it is "backed up".
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

[ -f .env ] || { echo "ERROR: .env missing (need RESTIC_PASSWORD etc.)."; exit 1; }
command -v restic >/dev/null 2>&1 || { echo "ERROR: restic not installed (sudo apt install restic)."; exit 1; }
command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not installed."; exit 1; }

env_value() {
  grep -E "^$1=" .env | tail -n1 | cut -d= -f2- \
    | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

BACKUP_DEST_PATH="$(env_value BACKUP_DEST_PATH)"
RESTIC_PASSWORD="$(env_value RESTIC_PASSWORD)"
LOCALCLOUD_PROFILES="$(env_value LOCALCLOUD_PROFILES)"
REPO="${BACKUP_DEST_PATH%/}/restic-repo"
SNAPSHOT="${1:-latest}"

[ -n "$RESTIC_PASSWORD" ] || { echo "ERROR: RESTIC_PASSWORD is not set in .env."; exit 1; }
[ -d "$REPO" ] || { echo "ERROR: restic repo not found at $REPO. Is the backup disk mounted?"; exit 1; }

export RESTIC_PASSWORD
export RESTIC_REPOSITORY="$REPO"

echo "==> Snapshots in $REPO:"
restic snapshots || { echo "ERROR: cannot open the restic repo (wrong RESTIC_PASSWORD?)."; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
scratch=".restore-$ts"

echo "==> Restoring snapshot '$SNAPSHOT' into $scratch"
# Run restic inside Podman's user namespace so restored files get the uid
# mapping the rootless containers expect. A plain non-root restore cannot set
# those owners, which would make n8n/Mattermost data unreadable on startup.
podman unshare restic restore "$SNAPSHOT" --target "$scratch"

SRC="$scratch/sources"
[ -d "$SRC" ] || { echo "ERROR: restored snapshot has no sources/ directory."; podman unshare rm -rf "$scratch"; exit 1; }

echo "==> Stopping the stack"
podman-compose -f docker-compose.yml down || true

mkdir -p data
for d in "$SRC"/*/; do
  s="$(basename "$d")"
  echo "==> Restoring data/$s"
  [ -e "data/$s" ] && podman unshare mv "data/$s" "data/$s.pre-restore-$ts"
  podman unshare mv "$d" "data/$s"
done
podman unshare rm -rf "$scratch"

# Re-enable any optional profiles configured in .env.
PROFILE_ARGS=""
for p in $(printf '%s' "$LOCALCLOUD_PROFILES" | tr ',' ' '); do
  [ -n "$p" ] && PROFILE_ARGS="$PROFILE_ARGS --profile $p"
done

echo "==> Bringing the stack up"
# shellcheck disable=SC2086
podman-compose -f docker-compose.yml $PROFILE_ARGS up -d

echo "Done. Previous data preserved as data/<svc>.pre-restore-$ts (delete once verified)."
echo "Mattermost PostgreSQL recovers automatically via WAL on first start."
