#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Resize the LUKS + ZFS volume.

ZFS pools cannot be shrunk in place on a single fixed vdev. This toolkit only
supports GROW. To move to a smaller backing store, use zfs send/receive to a
new pool.

Usage:
  sudo $0 expand [--percent N | --bytes N]

expand:
  Grows VOL_FILE, refreshes loop, cryptsetup resize, zpool online -e.
  Default: grow by PERCENT of current free space on STORAGE_ROOT (default PERCENT=$PERCENT).

Environment: STORAGE_ROOT, VOL_FILE, MAPPER_NAME, POOL_NAME, PERCENT
USAGE
}

expand_volume() {
  local add_bytes="$1"
  local cur loop mp
  cur=$(stat -c%s "$VOL_FILE")
  echo "Current file size: $(human_bytes "$cur")"
  echo "Growing file by: $(human_bytes "$add_bytes")"
  truncate -s $(( cur + add_bytes )) "$VOL_FILE"

  loop=$(loop_for_vol_file)
  if [[ -z "$loop" ]]; then
    loop=$(losetup --find --show "$VOL_FILE")
  else
    losetup -c "$loop"
  fi
  echo "Loop: $loop (refreshed)"

  if [[ ! -e "$(mapper_path)" ]]; then
    cryptsetup open "$loop" "$MAPPER_NAME"
  fi
  cryptsetup resize "$MAPPER_NAME"

  mp="$(mapper_path)"
  if ! is_pool_imported; then
    zpool import -d "$(dirname "$mp")" "$POOL_NAME"
  fi

  zpool set autoexpand=on "$POOL_NAME"
  zpool online -e "$POOL_NAME" "$mp"

  echo "Expand complete."
  zpool list "$POOL_NAME"
  zfs list -r "$POOL_NAME" | head -20
}

cmd="${1:-}"
shift || true
case "$cmd" in
  expand)
    require_root_for "$@"
    add_bytes=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --percent)
          p="$2"; shift 2
          add_bytes=$(target_bytes_from_percent "$p")
          ;;
        --bytes)
          add_bytes="$2"; shift 2
          ;;
        *) echo "Unknown: $1" >&2; usage; exit 1 ;;
      esac
    done
    if [[ -z "$add_bytes" ]]; then
      add_bytes=$(target_bytes_from_percent "$PERCENT")
    fi
    expand_volume "$add_bytes"
    ;;
  shrink|compact)
    echo "ZFS: in-place shrink of a pool on a loop/LUKS vdev is not supported." >&2
    echo "Use zfs send/receive to a new, smaller volume if you must reduce size." >&2
    exit 1
    ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
esac
