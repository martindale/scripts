#!/usr/bin/env bash
# Move ~/backups/<target>/ into the ZFS archive with rsync, then remove each
# source file only after it has been written to the destination (--remove-source-files).
# Empty directories may remain under ~/backups/<target>/ until cleaned (see --prune-empty).
set -euo pipefail

: "${ARCHIVE_MOUNT:=/media/archive}"
: "${BACKUPS_ROOT:=$HOME/backups}"

usage() {
  cat <<USAGE
Usage: sudo $0 [options] <target>

  Rsync ${BACKUPS_ROOT}/<target>/ -> ${ARCHIVE_MOUNT}/<target>/ and delete each
  source file after it is successfully transferred.

Options:
  --dry-run, -n     rsync dry run (no writes, no source deletions)
  --checksum, -c    rsync -c (verify block checksums; slower, stronger check)
  --prune-empty     after rsync, remove empty directories under source (find -delete)

Environment:
  ARCHIVE_MOUNT   default ${ARCHIVE_MOUNT}
  BACKUPS_ROOT    default ${BACKUPS_ROOT} (resolved symlink is fine)
  RSYNC_OPTS      extra rsync args (quoted string)

Requires root if ${ARCHIVE_MOUNT} is not writable as your user.

Remaining dirs you mentioned (examples):
  goliath  meta  mail.fabric.pub  mail.ericmartindale.com
USAGE
}

require_writable_dest() {
  if [[ ! -d "$ARCHIVE_MOUNT" ]]; then
    echo "Archive mount missing: $ARCHIVE_MOUNT (open the pool first?)" >&2
    exit 1
  fi
  if [[ ! -w "$ARCHIVE_MOUNT" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Cannot write $ARCHIVE_MOUNT; run with sudo or fix permissions." >&2
    exit 1
  fi
}

DRY=()
CHECK=()
PRUNE_EMPTY=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    -n | --dry-run) DRY=(--dry-run); shift ;;
    -c | --checksum) CHECK=(-c); shift ;;
    --prune-empty) PRUNE_EMPTY=1; shift ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage >&2
  exit 1
fi

if [[ "$TARGET" == *"/"* || "$TARGET" == "." || "$TARGET" == ".." ]]; then
  echo "Refusing target with path components: $TARGET" >&2
  exit 1
fi

SRC="${BACKUPS_ROOT%/}/${TARGET}/"
DST="${ARCHIVE_MOUNT%/}/${TARGET}/"

if [[ ! -d "$SRC" ]]; then
  echo "Source is not a directory: $SRC" >&2
  exit 1
fi

require_writable_dest

mkdir -p "$DST"

# shellcheck disable=SC2206
RSYNC_EXTRA=(${RSYNC_OPTS:-})

echo "rsync ${CHECK[*]} ${DRY[*]} --remove-source-files $SRC -> $DST" >&2
rsync -aH "${CHECK[@]}" "${DRY[@]}" --info=progress2 \
  --remove-source-files \
  "${RSYNC_EXTRA[@]}" \
  "$SRC" "$DST"

if [[ ${#DRY[@]} -eq 0 && "$PRUNE_EMPTY" -eq 1 ]]; then
  find "$SRC" -depth -type d -empty -delete 2>/dev/null || true
fi

echo "Done: $SRC -> $DST"
