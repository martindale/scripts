#!/usr/bin/env bash
# Move ~/backups/<target>/ into the ZFS archive with rsync, then remove each
# source file only after it has been written to the destination (--remove-source-files).
# Empty directories may remain under ~/backups/<target>/ until cleaned (see --prune-empty).
set -euo pipefail

: "${ARCHIVE_MOUNT:=/media/archive}"

# With sudo, $HOME is often /root — default BACKUPS_ROOT to the invoking user's ~/backups.
if [[ -z "${BACKUPS_ROOT:-}" ]]; then
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    BACKUPS_ROOT="$(getent passwd -- "$SUDO_USER" | cut -d: -f6)/backups"
  else
    BACKUPS_ROOT="${HOME}/backups"
  fi
fi

usage() {
  cat <<USAGE
Usage: sudo $0 [options] <target | /path/to/source/>

  Mode A — basename only:
    Rsync ${BACKUPS_ROOT}/<target>/ -> ${ARCHIVE_MOUNT}/<target>/

  Mode B — path (contains /):
    Rsync that directory -> ${ARCHIVE_MOUNT}/<basename>/

  Uses rsync --remove-source-files (source files removed only after successful copy).

Options:
  --dry-run, -n     rsync dry run (no writes, no source deletions)
  --checksum, -c    rsync -c (verify block checksums; slower, stronger check)
  --prune-empty     after rsync, remove empty directories under source (find -delete)

Environment:
  ARCHIVE_MOUNT   default ${ARCHIVE_MOUNT}
  BACKUPS_ROOT    default ${BACKUPS_ROOT} (under sudo: /home/<SUDO_USER>/backups)
  RSYNC_OPTS      extra rsync args (quoted string)

Examples:
  sudo $0 git.roleplaygateway.com
  sudo $0 /home/eric/backups/git.roleplaygateway.com
  sudo env BACKUPS_ROOT=/home/eric/storage/backups $0 meta
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

# Expand leading ~ using the real user's home when root (quoted "~/backups/foo").
if [[ "$TARGET" == "~" || "$TARGET" == "~/"* ]]; then
  _uh="$(getent passwd -- "${SUDO_USER:-$USER}" | cut -d: -f6)"
  TARGET="${TARGET/#\~/${_uh}}"
fi

ARCHIVE_NAME=""

if [[ "$TARGET" == *"/"* ]]; then
  if [[ "$TARGET" =~ (^|/)\.\.(/|$) ]]; then
    echo "Refusing path with '..': $TARGET" >&2
    exit 1
  fi
  _src="${TARGET%/}"
  if [[ ! -d "$_src" ]]; then
    echo "Source is not a directory: $_src" >&2
    exit 1
  fi
  SRC="${_src}/"
  ARCHIVE_NAME="$(basename "$_src")"
  if [[ -z "$ARCHIVE_NAME" || "$ARCHIVE_NAME" == "." || "$ARCHIVE_NAME" == ".." ]]; then
    echo "Invalid archive name from path: $TARGET" >&2
    exit 1
  fi
else
  if [[ "$TARGET" == "." || "$TARGET" == ".." ]]; then
    echo "Refusing target: $TARGET" >&2
    exit 1
  fi
  SRC="${BACKUPS_ROOT%/}/${TARGET}/"
  ARCHIVE_NAME="$TARGET"
fi

DST="${ARCHIVE_MOUNT%/}/${ARCHIVE_NAME}/"

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
