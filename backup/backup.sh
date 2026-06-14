#!/bin/sh
set -e

SRC_ROOT="/sources"
DEST_ROOT="/backup"

# Safety: abort if /backup is not a real mount point.
# Without this, a missing USB mount would silently rsync all data onto
# the host's root filesystem instead of the USB drive.
if [ "$BACKUP_REQUIRE_MOUNT" = "true" ] && ! mountpoint -q "$DEST_ROOT"; then
  echo "[$(date)] ERROR: $DEST_ROOT is not a mount point. USB drive not mounted? Aborting backup to prevent filling host filesystem." >> /var/log/backup.log
  exit 1
fi

if [ -d "$SRC_ROOT" ]; then
  for service_dir in "$SRC_ROOT"/*/; do
    [ -d "$service_dir" ] || continue
    service_name=$(basename "$service_dir")
    mkdir -p "$DEST_ROOT/$service_name"
    rsync -aAXH --numeric-ids --delete "$service_dir" "$DEST_ROOT/$service_name/"
  done
fi
