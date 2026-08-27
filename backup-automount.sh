#!/usr/bin/env bash
# Make the backup disk mount itself at boot, so the nightly backup survives a
# power cut with nobody present. Without this, a disk mounted by hand is gone
# after an outage: the volume marker disappears, the backup aborts, and it keeps
# aborting every night until someone notices.
#
# Handles both shapes of backup disk:
#   * LUKS-encrypted  - adds a root-only keyfile, an /etc/crypttab entry, and an
#                       /etc/fstab entry for the unlocked mapper.
#   * plain filesystem - adds an /etc/fstab entry only.
#
# Run this once, deliberately. install.sh never calls it: editing /etc/fstab and
# adding a LUKS key slot are host-level changes that must be an explicit
# operator decision, not a side effect of installing the stack.
#
#   ./backup-automount.sh --device /dev/sdc1
#   ./backup-automount.sh --device /mnt/usb-disk      # a mounted path is resolved
#   ./backup-automount.sh --device /dev/sdc1 --rollback
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
  ./backup-automount.sh --device <partition|mounted-path> [--name localcloud-backup] [--yes]
  ./backup-automount.sh --device <partition|mounted-path> --rollback [--yes]

  --device    backup partition (e.g. /dev/sdc1), or a path where it is already
              mounted (e.g. /mnt/usb-disk), which is resolved to the device
  --name      device-mapper name for a LUKS disk (default: localcloud-backup)
  --rollback  undo: remove the fstab entry, and for LUKS also the crypttab
              entry, the key slot, and the keyfile
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
require_command blkid
require_command findmnt
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
  *) fail "BACKUP_DEST_PATH='$MOUNT_POINT' is not an absolute path. Boot-time mounting needs a real mount point such as /mnt/usb-disk, not a development directory." ;;
esac
MOUNT_POINT="${MOUNT_POINT%/}"

# Accept a mounted path in place of the device; passing the mount point is the
# obvious mistake and resolving it is friendlier than rejecting it.
if [ ! -b "$DEVICE" ] && [ -d "$DEVICE" ]; then
  resolved="$(findmnt -no SOURCE --target "$DEVICE" 2>/dev/null || true)"
  [ -b "$resolved" ] || fail "$DEVICE is not a block device and nothing is mounted there. Pass the partition from 'lsblk -f', for example /dev/sdc1."
  info "Resolved $DEVICE to $resolved"
  DEVICE="$resolved"
fi
[ -b "$DEVICE" ] || fail "$DEVICE is not a block device. Check 'lsblk -f'."

IS_LUKS=false
if command -v cryptsetup >/dev/null 2>&1 && sudo cryptsetup isLuks "$DEVICE" 2>/dev/null; then
  IS_LUKS=true
fi

CRYPTTAB="/etc/crypttab"
FSTAB="/etc/fstab"
CRYPTTAB_MARK="# localcloud-stack: backup disk auto-unlock"
FSTAB_MARK="# localcloud-stack: backup disk"

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

luks_slot_count() {
  sudo cryptsetup luksDump "$DEVICE" \
    | awk '/^Key Slot [0-7]: ENABLED/ { c++ } /^[[:space:]]+[0-7]: luks2/ { c++ } END { print c+0 }'
}

remove_fstab_entry() {
  sudo sed -i "\\|^${FSTAB_MARK}\$|d; \\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" "$FSTAB"
}

if [ "$ROLLBACK" = true ]; then
  info "Rolling back boot-time mounting of $MOUNT_POINT"
  remove_fstab_entry
  info "Removed the $MOUNT_POINT entry from $FSTAB."

  if [ "$IS_LUKS" = true ]; then
    slots="$(luks_slot_count)"
    if [ "${slots:-0}" -lt 2 ]; then
      warn "$DEVICE has ${slots:-0} enabled key slot(s); leaving the key slot and keyfile in place. Removing the only slot would lock you out of the backup disk permanently."
    else
      confirm "Remove the keyfile key slot from $DEVICE and destroy $KEYFILE?"
      if sudo test -f "$KEYFILE"; then
        sudo cryptsetup luksRemoveKey "$DEVICE" --key-file "$KEYFILE" \
          || warn "luksRemoveKey failed; the key slot may already be gone."
        sudo shred -u "$KEYFILE" 2>/dev/null || sudo rm -f "$KEYFILE"
        info "Key slot removed and keyfile destroyed."
      else
        warn "$KEYFILE not present; skipping key slot removal."
      fi
    fi
    sudo sed -i "\\|^${CRYPTTAB_MARK}\$|d; \\|^${MAPPER_NAME}[[:space:]]|d" "$CRYPTTAB" 2>/dev/null || true
    info "Removed the $MAPPER_NAME entry from $CRYPTTAB."
    info "Verify your passphrase still opens the disk: sudo cryptsetup open $DEVICE $MAPPER_NAME"
  fi

  sudo systemctl daemon-reload
  info "Rolled back. $MOUNT_POINT now needs mounting by hand after every boot."
  exit 0
fi

if [ "$IS_LUKS" = true ]; then
  info "$DEVICE is LUKS-encrypted; configuring keyfile unlock plus boot-time mount"

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

  # 2. Header backup, before anything touches the header.
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
    sudo cryptsetup luksAddKey "$DEVICE" "$KEYFILE" || fail "luksAddKey failed. The disk is unchanged."
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
    printf '%s\n%s UUID=%s %s luks,nofail\n' "$CRYPTTAB_MARK" "$MAPPER_NAME" "$UUID" "$KEYFILE" \
      | sudo tee -a "$CRYPTTAB" >/dev/null
    info "Added $MAPPER_NAME to $CRYPTTAB (UUID=$UUID, nofail)."
  fi

  FS_SOURCE="/dev/mapper/$MAPPER_NAME"
  FSTYPE="$(sudo blkid -s TYPE -o value "$FS_SOURCE" 2>/dev/null || true)"
  if [ -z "$FSTYPE" ]; then
    FSTYPE="ext4"
    warn "Could not detect the filesystem type (the mapper is not open); assuming $FSTYPE. Correct $FSTAB by hand if that is wrong."
  fi
else
  info "$DEVICE is not LUKS-encrypted; configuring boot-time mount only"
  info "Snapshots are still encrypted at rest by restic under RESTIC_PASSWORD. Disk encryption would add a second layer, not the only one - see SECURITY.md."

  UUID="$(sudo blkid -s UUID -o value "$DEVICE")"
  [ -n "$UUID" ] || fail "Could not read a UUID for $DEVICE."
  FSTYPE="$(sudo blkid -s TYPE -o value "$DEVICE")"
  [ -n "$FSTYPE" ] || fail "Could not detect a filesystem on $DEVICE."
  # UUID rather than /dev/sdX: device names are assigned in probe order and can
  # move between boots, which would point fstab at the wrong disk.
  FS_SOURCE="UUID=$UUID"
fi

# fstab. nofail is not optional: without it a disk that is absent, dead, or
# unplugged blocks boot on a machine that may only be reachable over the
# network - trading a stopped backup for an unreachable server.
if grep -qE "[[:space:]]${MOUNT_POINT}[[:space:]]" "$FSTAB"; then
  info "$FSTAB already mounts $MOUNT_POINT; leaving it alone."
else
  confirm "Add $MOUNT_POINT to $FSTAB ($FS_SOURCE, $FSTYPE, nofail)?"
  sudo mkdir -p "$MOUNT_POINT"
  printf '%s\n%s %s %s defaults,nofail,x-systemd.device-timeout=30 0 2\n' \
    "$FSTAB_MARK" "$FS_SOURCE" "$MOUNT_POINT" "$FSTYPE" \
    | sudo tee -a "$FSTAB" >/dev/null
  info "Added $MOUNT_POINT to $FSTAB ($FSTYPE, nofail, 30s device timeout)."
fi

sudo systemctl daemon-reload

# Test. Only exercise the mount path when the disk is not already in use --
# unmounting a live backup disk out from under a running stack is not a test
# worth running.
if mountpoint -q "$MOUNT_POINT"; then
  info "$MOUNT_POINT is already mounted; skipping the offline mount test."
  info "Checking that the new fstab entry parses:"
  sudo findmnt --verify --verbose "$MOUNT_POINT" || warn "findmnt --verify reported problems; review $FSTAB before rebooting."
else
  info "Testing the mount path"
  if [ "$IS_LUKS" = true ]; then
    if command -v cryptdisks_start >/dev/null 2>&1; then
      sudo cryptdisks_start "$MAPPER_NAME"
    else
      sudo systemctl start "systemd-cryptsetup@$(systemd-escape "$MAPPER_NAME").service"
    fi
  fi
  sudo mount -a
  mountpoint -q "$MOUNT_POINT" || fail "$MOUNT_POINT still is not mounted. Review $FSTAB before rebooting."
  info "Mount test passed."
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

      mountpoint -q $MOUNT_POINT && echo "auto-mount works"
      podman logs backup 2>&1 | tail -20

    The mount happens in early boot, before the lingering user session starts
    the stack, so the backup container sees the real disk. Undo at any time:

      ./backup-automount.sh --device $DEVICE --rollback
EOF
