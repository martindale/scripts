#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_root_for "$@"

if [[ ! -f "$VOL_FILE" ]]; then
  echo "Missing VOL_FILE: $VOL_FILE" >&2
  exit 1
fi

LOOP=$(loop_for_vol_file)
if [[ -z "$LOOP" ]]; then
  LOOP=$(losetup --find --show "$VOL_FILE")
  echo "Attached $LOOP"
else
  echo "Using existing loop $LOOP"
fi

if [[ ! -e "$(mapper_path)" ]]; then
  cryptsetup open "$LOOP" "$MAPPER_NAME"
fi

if is_pool_imported; then
  zfs mount -a || true
  echo "Pool $POOL_NAME already imported"
else
  zpool import -d "$(dirname "$(mapper_path)")" "$POOL_NAME"
fi

echo "Mounted (or ready) at $MOUNTPOINT"
zfs get -H -o value mountpoint "$POOL_NAME" | head -1 || true
