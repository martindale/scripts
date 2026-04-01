#!/usr/bin/env bash
# Recursively find regular files that look like LUKS-encrypted payloads (typical
# for loop-mounted .img volumes). Does not open devices or require root.
set -euo pipefail

usage() {
  cat <<'USAGE'
Scan a directory tree for LUKS-encrypted files (loopback image candidates).

Uses file(1) magic on each candidate. Symlinks are not followed.

Usage:
  scan-luks-images.sh [options] [DIRECTORY]

Arguments:
  DIRECTORY          Root to scan (default: ~/backups)

Options:
  -h, --help         Show this help
  -d, --max-depth N  find(1) -maxdepth N (omit for unlimited)
  -s, --min-size S   find(1) -size test (default: +1M), e.g. +100M, +10G
  -p, --pattern GLOB find(1) -name glob, e.g. '*.img' or '*.raw'
  -q, --quiet        Print paths only (no size / file description)
  -0, --print0       NUL-terminated paths (for xargs -0)
  --quick            Check first 6 bytes for LUKS magic (faster on huge trees;
                     description column shows "LUKS magic (quick)"). Needs head.

Examples:
  ~/scripts/luks-backup-volume/scan-luks-images.sh ~/backups
  ~/scripts/luks-backup-volume/scan-luks-images.sh -p '*.img' /media/storage/backups
  ~/scripts/luks-backup-volume/scan-luks-images.sh -s +500M -q ~/backups | while read -r f; do file -b "$f"; done

Recovery hint: inspect with `file PATH` and `cryptsetup luksDump PATH`, then attach
with losetup + cryptsetup open (see open.sh patterns in this directory).
USAGE
}

MAX_DEPTH=""
MIN_SIZE="+1M"
PATTERN=""
QUIET=0
PRINT0=0
QUICK=0
ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -d | --max-depth)
      MAX_DEPTH="${2:?}"
      shift 2
      ;;
    -s | --min-size)
      MIN_SIZE="${2:?}"
      shift 2
      ;;
    -p | --pattern)
      PATTERN="${2:?}"
      shift 2
      ;;
    -q | --quiet)
      QUIET=1
      shift
      ;;
    -0 | --print0)
      PRINT0=1
      shift
      ;;
    --quick)
      QUICK=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$ROOT" ]]; then
        echo "Extra argument: $1" >&2
        exit 1
      fi
      ROOT="$1"
      shift
      ;;
  esac
done

ROOT="${ROOT:-$HOME/backups}"

if [[ ! -d "$ROOT" ]]; then
  echo "Not a directory: $ROOT" >&2
  exit 1
fi

human_size() {
  local path="$1" bytes
  if bytes=$(stat -c%s "$path" 2>/dev/null); then
    :
  elif bytes=$(stat -f%z "$path" 2>/dev/null); then
    :
  else
    echo "?"
    return
  fi
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    echo "${bytes}B"
  fi
}

find_args=("$ROOT" -type f -size "$MIN_SIZE")
if [[ -n "$MAX_DEPTH" ]]; then
  find_args+=(-maxdepth "$MAX_DEPTH")
fi
if [[ -n "$PATTERN" ]]; then
  find_args+=(-name "$PATTERN")
fi

# LUKS magic at offset 0: "LUKS" + 0xba 0xbe (LUKS1/LUKS2)
luks_magic_match() {
  local f="$1"
  local hex
  if command -v xxd >/dev/null 2>&1; then
    hex=$(head -c 6 "$f" 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n') || return 1
  else
    hex=$(head -c 6 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n') || return 1
  fi
  [[ "$hex" == "4c554b53babe" ]]
}

identify_luks() {
  local f="$1"
  if [[ "$QUICK" -eq 1 ]]; then
    if luks_magic_match "$f"; then
      echo "LUKS magic (quick)"
      return 0
    fi
    return 1
  fi
  local ft
  ft=$(file -b "$f" 2>/dev/null || true)
  [[ "$ft" == LUKS* ]] || return 1
  printf '%s\n' "$ft"
}

count=0
while IFS= read -r -d '' f; do
  ft=$(identify_luks "$f") || continue

  count=$((count + 1))
  if [[ "$PRINT0" -eq 1 ]]; then
    printf '%s\0' "$f"
  elif [[ "$QUIET" -eq 1 ]]; then
    printf '%s\n' "$f"
  else
    printf '%s\t%s\t%s\n' "$f" "$(human_size "$f")" "$ft"
  fi
done < <(find "${find_args[@]}" -print0 2>/dev/null)

if [[ "$PRINT0" -eq 0 && "$QUIET" -eq 0 ]]; then
  echo "# total: $count LUKS file(s) under $ROOT" >&2
fi
