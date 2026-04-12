#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_root_for "$@"

export_pool() {
  if ! is_pool_imported; then
    return 0
  fi
  if zpool export "$POOL_NAME"; then
    echo "Exported pool $POOL_NAME"
    return 0
  fi

  echo "" >&2
  echo "zpool export failed (mount busy or unreplicated writes). Find holders:" >&2
  echo "  sudo fuser -vm $MOUNTPOINT" >&2
  echo "  sudo lsof +D $MOUNTPOINT 2>/dev/null | head -50" >&2
  echo "  findmnt -rn $MOUNTPOINT" >&2
  echo "" >&2
  echo "Stop rsync/backup jobs, shells with cwd under the archive, Docker binds, etc." >&2
  if [[ "${FORCE_EXPORT:-}" == "1" ]]; then
    echo "FORCE_EXPORT=1: forcing export (may interrupt writers; data loss risk)." >&2
    zpool export -f "$POOL_NAME"
    echo "Exported pool $POOL_NAME (forced)"
    return 0
  fi
  echo "To override after stopping what you can: sudo env FORCE_EXPORT=1 $0" >&2
  return 1
}

export_pool

if [[ -e "$(mapper_path)" ]]; then
  cryptsetup close "$MAPPER_NAME"
  echo "Closed mapper $MAPPER_NAME"
fi

LOOP=$(loop_for_vol_file)
if [[ -n "$LOOP" ]]; then
  losetup -d "$LOOP"
  echo "Detached $LOOP"
fi

echo "Done."
