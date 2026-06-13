#!/bin/sh
set -e

SRC_ROOT="/sources"
DEST_ROOT="/backup"

if [ -d "$SRC_ROOT" ]; then
  for service_dir in "$SRC_ROOT"/*/; do
    [ -d "$service_dir" ] || continue
    service_name=$(basename "$service_dir")
    mkdir -p "$DEST_ROOT/$service_name"
    rsync -aAXH --numeric-ids --delete "$service_dir" "$DEST_ROOT/$service_name/"
  done
fi
