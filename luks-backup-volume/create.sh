#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Create a new LUKS-encrypted loop file on STORAGE_ROOT (default $STORAGE_ROOT),
sized to PERCENT of remaining free space (default ${PERCENT}%).

Inside LUKS: one ZFS pool with compression (${ZFS_COMPRESSION}) and dedup (${ZFS_DEDUP}).

Environment (optional):
  STORAGE_ROOT      mount to measure free space (default /media/storage)
  VOL_FILE          backing file path (default \$STORAGE_ROOT/backup-archive.img)
  PERCENT           1-100 (default 50)
  ALLOCATE          sparse|full (default sparse)
  MAPPER_NAME       cryptsetup name (default backup_crypt)
  MOUNTPOINT        ZFS pool mountpoint (default /mnt/backup-archive)
  POOL_NAME         zpool name (default backup_pool)
  ZFS_COMPRESSION   e.g. zstd, zstd-3, lz4 (default zstd)
  ZFS_DEDUP         on|off|verify (default on — needs lots of RAM; see README)

Steps: size file -> losetup -> luksFormat (interactive passphrase) ->
       open -> zpool create -> mounted at MOUNTPOINT

Then: rsync into MOUNTPOINT; use status.sh / dedupe.sh to inspect DDT.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
require_root_for "$@"

if [[ -e "$VOL_FILE" ]]; then
  echo "Refusing to overwrite existing VOL_FILE: $VOL_FILE" >&2
  exit 1
fi

TARGET=$(target_bytes_from_percent "$PERCENT")
echo "Free on $STORAGE_ROOT: $(human_bytes "$(bytes_avail_on_storage)")"
echo "Creating $(human_bytes "$TARGET") (${PERCENT}% of free) at $VOL_FILE"

mkdir -p "$(dirname "$VOL_FILE")"
if [[ "$ALLOCATE" == "full" ]]; then
  fallocate -l "$TARGET" "$VOL_FILE"
elif [[ "$ALLOCATE" == "sparse" ]]; then
  truncate -s "$TARGET" "$VOL_FILE"
else
  echo "ALLOCATE must be sparse or full (got $ALLOCATE)" >&2
  exit 1
fi

LOOP=$(losetup --find --show "$VOL_FILE")
echo "Loop device: $LOOP"

echo "LUKS format (you will be prompted for passphrase)..."
cryptsetup luksFormat --verify-passphrase "$LOOP"

cryptsetup open "$LOOP" "$MAPPER_NAME"
MP="$(mapper_path)"
echo "Opened mapper: $MP"

if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
  echo "Pool $POOL_NAME already exists; refusing." >&2
  exit 1
fi

zpool create -f \
  -o autoexpand=on \
  -O compression="$ZFS_COMPRESSION" \
  -O dedup="$ZFS_DEDUP" \
  -O atime=off \
  -m "$MOUNTPOINT" \
  "$POOL_NAME" \
  "$MP"

echo "Pool $POOL_NAME created, mounted at $MOUNTPOINT"
echo "Example: rsync -av --progress ~/backups/some/ $MOUNTPOINT/"
echo "Dedup is handled by ZFS (property dedup=$ZFS_DEDUP). Inspect: sudo $SCRIPT_DIR/status.sh"
