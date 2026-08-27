#!/usr/bin/env bash
# Configure the LUKS backup disk to unlock and mount itself at boot, so the
# nightly backup survives a power cut with nobody present.
#
# Run this once, deliberately. install.sh never calls it: adding a LUKS key slot
# and editing /etc/crypttab and /etc/fstab are host-level changes that must be an
# explicit operator decision, not a side effect of installing the stack.
#
# The trade: the keyfile lives on the host root disk, so the backup disk stays
# protected if it is lost, sold, returned under warranty, or stolen on its own,
# and stops protecting anything once the whole machine is taken. Choose this when
# the server sits somewhere physically controlled.
#
#   ./backup-autounlock.sh --device /dev/sdX1
#   ./backup-autounlock.sh --device /dev/sdX1 --rollback
set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

MAPPER_NAME="localcloud-backup"
KEYFILE="/etc/localcloud-backup.key"
DEVICE=""
ROLLBACK=false
ASSUME_YES=false

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./backup-autounlock.sh --device /dev/sdX1 [--name localcloud-backup] [--yes]
  ./backup-autounlock.sh --device /dev/sdX1 --rollback [--yes]

  --device    LUKS partition holding the backup filesystem (required)
  --name      device-mapper name to use in /etc/crypttab (default: localcloud-backup)
  --rollback  remove the crypttab/fstab entries, drop the key slot, destroy the keyfile
  --yes       do not prompt for confirmation
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --name) MAPPER_NAME="${2:-}"; shift 2 ;;
    --rollback) ROLLBACK=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[ -n "$DEVICE" ] || { usage >&2; fail "--device is required."; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}
require_command cryptsetup
require_command blkid
require_command sudo

# Reuse the same .env parsing as install.sh so BACKUP_DEST_PATH cannot drift.
env_value() {
  local key="$1" value
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

[ -f .env ] || fail ".env not found. Run ./install.sh first."
MOUNT_POINT="$(env_value BACKUP_DEST_PATH)"
[ -n "$MOUNT_POINT" ] || fail "BACKUP_DEST_PATH is not set in .env."
case "$MOUNT_POINT" in
  /*) ;;
  *) fail "BACKUP_DEST_PATH='$MOUNT_POINT' is not an absolute path. Auto-unlock needs a real mount point such as /mnt/usb-disk, not a development directory." ;;
esac
MOUNT_POINT="${MOUNT_POINT%/}"

confirm() {
  [ "$ASSUME_YES" = true ] && return 0
  printf '%s [y/N] ' "$1"
  local reply
  read -r reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) fail "Aborted." ;;
  esac
}

sudo cryptsetup isLuks "$DEVICE" 2>/dev/null \
  || fail "$DEVICE is not a LUKS device. Check 'lsblk -f' and pass the encrypted partition, not the mapper or the filesystem."

CRYPTTAB="/etc/crypttab"
FSTAB="/etc/fstab"
CRYPTTAB_MARK="# localcloud-stack: backup disk auto-unlock"
FSTAB_MARK="# localcloud-stack: backup disk"

if [ "$ROLLBACK" = true ]; then
  info "Rolling back auto-unlock for $DEVICE ($MAPPER_NAME)"

  slots="$(sudo cryptsetup luksDump "$DEVICE" | grep -c '^[[:space:]]*[0-9]\+: luks2\|^Key Slot [0-7]: ENABLED' || true)"
  if [ "${slots:-0}" -lt 2 ]; then
    fail "Refusing to remove a key slot: $DEVICE appears to have fewer than two enabled slots. Add your passphrase back before rolling back, or you will be locked out of the backup disk permanently."
  fi

  confirm "Remove the keyfile key slot from $DEVICE and delete $KEYFILE?"

  if [ -f "$KEYFILE" ]; then
    sudo cryptsetup luksRemoveKey "$DEVICE" "$KEYFILE" \
      || warn "luksRemoveKey failed; the key slot may already be gone."
    sudo shred -u "$KEYFILE" 2>/dev/null || sudo rm -f "$KEYFILE"
    info "Keyfile destroyed."
  else
    warn "$KEYFILE not present; skipping key slot removal."
  fi

  sudo sed -i "\|^${MAPPER_NAME}[[:space:]]|d; \|^${CRYPTTAB_MARK}\$|d" "$CRYPTTAB" 2>/dev/null || true
  sudo sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d; \|^${FSTAB_MARK}\$|d" "$FSTAB"
  sudo systemctl daemon-reload

  info "Rolled back. The disk now needs a manual 'cryptsetup open' after every boot."
  info "Verify your passphrase still opens it: sudo cryptsetup open $DEVICE $MAPPER_NAME"
  exit 0
fi

info "Configuring boot-time unlock for $DEVICE -> /dev/mapper/$MAPPER_NAME -> $MOUNT_POINT"

# 1. Keyfile.
if sudo test -f "$KEYFILE"; then
  info "Keyfile $KEYFILE already exists; reusing it."
else
  confirm "Create a root-only keyfile at $KEYFILE?"
  sudo dd if=/dev/urandom of="$KEYFILE" bs=512 count=8 status=none
  sudo chown root:root "$KEYFILE"
  sudo chmod 400 "$KEYFILE"
  info "Created $KEYFILE (mode 400, root-owned)."
fi

# 2. LUKS header backup, before anything touches the header.
HEADER_BACKUP="$HOME/localcloud-luks-header-$(date +%Y%m%d-%H%M%S).img"
sudo cryptsetup luksHeaderBackup "$DEVICE" --header-backup-file "$HEADER_BACKUP"
sudo chown "$(id -u):$(id -g)" "$HEADER_BACKUP"
chmod 600 "$HEADER_BACKUP"
info "LUKS header backed up to $HEADER_BACKUP"
warn "Copy that header off this machine, next to RESTIC_PASSWORD. A damaged header makes every snapshot unrecoverable regardless of passwords."

# 3. Key slot. Idempotent: skip when the keyfile already opens the device.
if sudo cryptsetup open --test-passphrase --key-file "$KEYFILE" "$DEVICE" 2>/dev/null; then
  info "Keyfile already unlocks $DEVICE; no new key slot needed."
else
  info "Adding the keyfile as an ADDITIONAL key slot. Your existing passphrase is kept."
  info "You will be prompted for that existing passphrase now."
  sudo cryptsetup luksAddKey "$DEVICE" "$KEYFILE" \
    || fail "luksAddKey failed. The disk is unchanged."
  sudo cryptsetup open --test-passphrase --key-file "$KEYFILE" "$DEVICE" \
    || fail "The keyfile still does not open $DEVICE. Refusing to continue."
  info "Key slot added and verified."
fi

# 4. crypttab, keyed by UUID so a renamed device cannot point at the wrong disk.
UUID="$(sudo blkid -s UUID -o value "$DEVICE")"
[ -n "$UUID" ] || fail "Could not read a UUID for $DEVICE."

if grep -qE "^${MAPPER_NAME}[[:space:]]" "$CRYPTTAB" 2>/dev/null; then
  info "$CRYPTTAB already has an entry for $MAPPER_NAME; leaving it alone."
else
  # nofail is not optional: without it an absent or dead disk blocks boot on a
  # machine that may only be reachable over the network.
  printf '%s\n%s UUID=%s %s luks,nofail\n' "$CRYPTTAB_MARK" "$MAPPER_NAME" "$UUID" "$KEYFILE" \
    | sudo tee -a "$CRYPTTAB" >/dev/null
  info "Added $MAPPER_NAME to $CRYPTTAB (UUID=$UUID, nofail)."
fi

# 5. fstab.
FSTYPE="$(sudo blkid -s TYPE -o value "/dev/mapper/$MAPPER_NAME" 2>/dev/null || true)"
if [ -z "$FSTYPE" ]; then
  FSTYPE="ext4"
  warn "Could not detect the filesystem type (the mapper is not open); assuming $FSTYPE. Correct $FSTAB by hand if that is wrong."
fi

if grep -qE "[[:space:]]${MOUNT_POINT}[[:space:]]" "$FSTAB"; then
  info "$FSTAB already mounts $MOUNT_POINT; leaving it alone."
else
  sudo mkdir -p "$MOUNT_POINT"
  printf '%s\n/dev/mapper/%s %s %s defaults,nofail,x-systemd.device-timeout=30 0 2\n' \
    "$FSTAB_MARK" "$MAPPER_NAME" "$MOUNT_POINT" "$FSTYPE" \
    | sudo tee -a "$FSTAB" >/dev/null
  info "Added $MOUNT_POINT to $FSTAB ($FSTYPE, nofail, 30s device timeout)."
fi

sudo systemctl daemon-reload

# 6. Test. Only exercise the unlock path when the disk is not already in use --
# unmounting a live backup disk out from under a running stack is not a test
# worth running.
if mountpoint -q "$MOUNT_POINT"; then
  info "$MOUNT_POINT is currently mounted; skipping the offline unlock test."
else
  info "Testing the unlock path"
  if command -v cryptdisks_start >/dev/null 2>&1; then
    sudo cryptdisks_start "$MAPPER_NAME"
  else
    sudo systemctl start "systemd-cryptsetup@$(systemd-escape "$MAPPER_NAME").service"
  fi
  sudo mount -a
  mountpoint -q "$MOUNT_POINT" || fail "$MOUNT_POINT still is not mounted. Review $CRYPTTAB and $FSTAB before rebooting."
  info "Unlock test passed."
fi

if [ -f "$MOUNT_POINT/.localcloud-backup-volume" ]; then
  info "Backup volume marker present."
else
  warn "Marker $MOUNT_POINT/.localcloud-backup-volume is missing. Run ./install.sh to recreate it, or scheduled backups will keep aborting."
fi

cat <<EOF

==> Done. Now verify the real path, because the test above does not exercise
    boot ordering:

      sudo reboot

    After it comes back:

      mountpoint -q $MOUNT_POINT && echo "auto-unlock works"
      podman logs backup 2>&1 | tail -20

    The mount happens in early boot, before the lingering user session starts
    the stack, so the backup container sees the real disk. Restore the manual
    behavior at any time with:

      ./backup-autounlock.sh --device $DEVICE --rollback
EOF
