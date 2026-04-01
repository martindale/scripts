#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== archive image =="
if [[ -f "$VOL_FILE" ]]; then
  ls -lh "$VOL_FILE"
else
  echo "missing: $VOL_FILE"
fi

echo
echo "== loop =="
losetup -j "$VOL_FILE" || true

echo
echo "== mapper =="
if [[ -e "$(mapper_path)" ]]; then
  ls -l "$(mapper_path)"
  lsblk -f "$(mapper_path)" || true
else
  echo "$(mapper_path) not present"
fi

echo
echo "== zpool =="
if is_pool_imported; then
  zpool list "$POOL_NAME"
  echo
  zfs get compression,dedup,mountpoint "$POOL_NAME"
  echo
  echo "== DDT (dedup table) — may be empty until data is written =="
  zpool status -D "$POOL_NAME" || true
else
  echo "Pool $POOL_NAME not imported (run sudo $SCRIPT_DIR/open.sh)"
  zpool list 2>/dev/null || true
fi
