#!/usr/bin/env bash
# Shared helpers for LUKS loop + ZFS backup volume (compression + dedup=on).
# shellcheck source=lib.sh

set -euo pipefail

: "${STORAGE_ROOT:=/media/storage}"
: "${VOL_FILE:=${STORAGE_ROOT}/archive.img}"
: "${MAPPER_NAME:=backup_crypt}"
: "${MOUNTPOINT:=/media/archive}"
: "${POOL_NAME:=backup_pool}"
: "${PERCENT:=50}"
: "${ALLOCATE:=sparse}"
: "${ZFS_COMPRESSION:=zstd}"
: "${ZFS_DEDUP:=on}"

require_root_for() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This step requires root; re-run with: sudo $0 $*" >&2
    exit 1
  fi
}

bytes_avail_on_storage() {
  df -B1 --output=avail "$STORAGE_ROOT" 2>/dev/null | tail -1 | tr -d ' '
}

target_bytes_from_percent() {
  local pct="$1"
  local avail
  avail=$(bytes_avail_on_storage)
  if ! [[ "$avail" =~ ^[0-9]+$ ]] || [[ "$avail" -le 0 ]]; then
    echo "Could not read free space on $STORAGE_ROOT" >&2
    exit 1
  fi
  if ! [[ "$pct" =~ ^[0-9]+$ ]] || [[ "$pct" -le 0 ]] || [[ "$pct" -gt 100 ]]; then
    echo "PERCENT must be 1-100 (got $pct)" >&2
    exit 1
  fi
  echo $(( avail * pct / 100 ))
}

human_bytes() {
  local b="$1"
  numfmt --to=iec-i --suffix=B "$b" 2>/dev/null || echo "${b} bytes"
}

# losetup/LUKS expect backing file length on a 512-byte boundary.
align_up_512() {
  local n="$1"
  echo $(( (n + 511) / 512 * 512 ))
}

# Grow VOL_FILE by 0–511 bytes if needed so the first losetup attach does not warn.
ensure_vol_file_loop_aligned() {
  local cur aligned
  cur=$(stat -c%s "$VOL_FILE")
  aligned=$(align_up_512 "$cur")
  if [[ "$aligned" -ne "$cur" ]]; then
    echo "Aligning $VOL_FILE to $(human_bytes "$aligned") (512-byte boundary for losetup/LUKS)." >&2
    truncate -s "$aligned" "$VOL_FILE"
  fi
}

loop_for_vol_file() {
  losetup -j "$VOL_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true
}

mapper_path() {
  echo "/dev/mapper/${MAPPER_NAME}"
}

is_pool_imported() {
  zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"
}

command -v cryptsetup >/dev/null || { echo "cryptsetup not found" >&2; exit 1; }
command -v zpool >/dev/null || { echo "zpool not found; install zfsutils-linux" >&2; exit 1; }
command -v zfs >/dev/null || { echo "zfs not found; install zfsutils-linux" >&2; exit 1; }
