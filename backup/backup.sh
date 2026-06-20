#!/bin/sh
set -e

SRC_ROOT="/sources"
DEST_ROOT="/backup"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$DEST_ROOT/restic-repo}"
RESTIC_HOST="${RESTIC_HOST:-localcloud}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-14}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-8}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"

export RESTIC_REPOSITORY RESTIC_PASSWORD

# Marker file that lives ON the backup volume (created once at install time).
# We check for it instead of `mountpoint -q "$DEST_ROOT"` because the compose
# bind-mount makes $DEST_ROOT *always* look like a mount point inside the
# container -- even when the real disk is unmounted on the host, the empty
# placeholder directory is bind-mounted instead, so `mountpoint` always
# succeeds. The marker only exists on the real volume, so its absence reliably
# means "not mounted -> abort instead of silently writing the backup onto the
# host filesystem".
MARKER="$DEST_ROOT/.localcloud-backup-volume"
FALLBACK_LOG="/var/log/backup.log"

abort() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] ERROR: $1" >> "$FALLBACK_LOG"
  exit 1
}

if [ "$BACKUP_REQUIRE_MOUNT" = "true" ] && [ ! -f "$MARKER" ]; then
  abort "marker $MARKER missing -- backup volume not mounted? Aborting to avoid writing to the host filesystem."
fi

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  abort "RESTIC_PASSWORD is not set. Aborting encrypted backup."
fi

if [ ! -d "$SRC_ROOT" ]; then
  abort "$SRC_ROOT does not exist. Nothing to back up."
fi

# Persistent log on the backup volume so run history survives container
# recreation (the guard above guarantees the volume is mounted by this point).
LOG="$DEST_ROOT/backup.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*" | tee -a "$LOG"; }

log "Backup started."

if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
  log "Initializing encrypted restic repository at $RESTIC_REPOSITORY"
  restic init
fi

restic backup "$SRC_ROOT" --host "$RESTIC_HOST" --tag localcloud
restic forget --host "$RESTIC_HOST" --tag localcloud \
  --keep-daily "$RESTIC_KEEP_DAILY" \
  --keep-weekly "$RESTIC_KEEP_WEEKLY" \
  --keep-monthly "$RESTIC_KEEP_MONTHLY" \
  --prune

log "Backup finished OK."
