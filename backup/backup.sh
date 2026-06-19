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

# Safety: abort if /backup is not a real mount point.
# Without this, a missing USB mount would silently rsync all data onto
# the host's root filesystem instead of the USB drive.
if [ "$BACKUP_REQUIRE_MOUNT" = "true" ] && ! mountpoint -q "$DEST_ROOT"; then
  echo "[$(date)] ERROR: $DEST_ROOT is not a mount point. USB drive not mounted? Aborting backup to prevent filling host filesystem." >> /var/log/backup.log
  exit 1
fi

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "[$(date)] ERROR: RESTIC_PASSWORD is not set. Aborting encrypted backup." >> /var/log/backup.log
  exit 1
fi

if [ ! -d "$SRC_ROOT" ]; then
  echo "[$(date)] ERROR: $SRC_ROOT does not exist. Nothing to back up." >> /var/log/backup.log
  exit 1
fi

if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
  echo "[$(date)] Initializing encrypted restic repository at $RESTIC_REPOSITORY" >> /var/log/backup.log
  restic init
fi

restic backup "$SRC_ROOT" \
  --host "$RESTIC_HOST" \
  --tag localcloud

restic forget \
  --host "$RESTIC_HOST" \
  --tag localcloud \
  --keep-daily "$RESTIC_KEEP_DAILY" \
  --keep-weekly "$RESTIC_KEEP_WEEKLY" \
  --keep-monthly "$RESTIC_KEEP_MONTHLY" \
  --prune
