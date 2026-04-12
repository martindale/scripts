#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Resize the LUKS + ZFS volume.

ZFS pools cannot be shrunk in place on a single fixed vdev. Use expand here;
to use a smaller (or re-laid-out) backing file, run shrink-migrate.sh
(zfs send/receive into a new LUKS image, then swap files).

Usage:
  sudo $0 expand [--percent N | --bytes N]

expand:
  Grows VOL_FILE, refreshes loop, cryptsetup resize, zpool online -e.
  Default: grow by PERCENT of current free space on STORAGE_ROOT (default PERCENT=$PERCENT).

shrink / shrink-migrate:
  Delegates to shrink-migrate.sh (same args). Example:
    sudo $SCRIPT_DIR/shrink-migrate.sh --dry-run --percent-of-alloc 115

Environment: STORAGE_ROOT, VOL_FILE, MAPPER_NAME, POOL_NAME, PERCENT
USAGE
}

# losetup/LUKS expect backing file length on a 512-byte boundary; avoid tail truncation warning.
align_up_512() {
  local n="$1"
  echo $(( (n + 511) / 512 * 512 ))
}

expand_volume() {
  local add_bytes="$1"
  local cur new_size loop mp
  cur=$(stat -c%s "$VOL_FILE")
  new_size=$(align_up_512 $(( cur + add_bytes )))
  echo "Current file size: $(human_bytes "$cur")"
  echo "Growing file by: $(human_bytes "$add_bytes") (aligned size: $(human_bytes "$new_size"))"
  if [[ "$new_size" -ne $(( cur + add_bytes )) ]]; then
    echo "Note: rounded total size up to next 512-byte boundary for loop/LUKS." >&2
  fi
  truncate -s "$new_size" "$VOL_FILE"

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

  # Expand is refused while the vdev is FAULTED (e.g. prior "too many errors" on full disk).
  if ! zpool list -H -o health "$POOL_NAME" 2>/dev/null | grep -qx ONLINE; then
    echo "Pool health is not ONLINE; attempting zpool clear before zpool online -e ..." >&2
    zpool clear "$POOL_NAME" 2>/dev/null || true
  fi
  if ! zpool online -e "$POOL_NAME" "$mp"; then
    echo "" >&2
    echo "zpool online -e failed. Check: zpool status -v $POOL_NAME" >&2
    echo "If the vdev is still FAULTED, fix underlying space/I/O, run: sudo zpool scrub $POOL_NAME" >&2
    echo "then: sudo zpool clear $POOL_NAME" >&2
    echo "Retry expand, or migrate to a new backing file (shrink-migrate.sh)." >&2
    exit 1
  fi

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
  shrink|shrink-migrate|migrate-smaller)
    exec "$SCRIPT_DIR/shrink-migrate.sh" "$@"
    ;;
  compact)
    echo "Use: sudo $SCRIPT_DIR/shrink-migrate.sh --dry-run ..." >&2
    echo "  or: sudo $0 shrink-migrate --execute ..." >&2
    exit 1
    ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
esac
