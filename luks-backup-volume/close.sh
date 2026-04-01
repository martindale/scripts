#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_root_for "$@"

if is_pool_imported; then
  zpool export "$POOL_NAME"
  echo "Exported pool $POOL_NAME"
fi

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
