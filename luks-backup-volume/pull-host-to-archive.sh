#!/usr/bin/env bash
# Pull a remote directory over SSH into /media/archive/<name>/ (copy; source unchanged).
# Intended to run on the archive host (e.g. martindale) with SSH access to the other host.
set -euo pipefail

: "${ARCHIVE_MOUNT:=/media/archive}"
: "${REMOTE_USER:=${SUDO_USER:-$USER}}"
: "${REMOTE_HOME_SUBDIR:=backups}"

usage() {
  cat <<USAGE
Usage: $0 [options] <host-or-archive-name> [remote_subdir]

  rsync ${REMOTE_USER}@<host>:~/<remote_subdir>/ -> ${ARCHIVE_MOUNT}/<archive-name>/

  First argument is the SSH hostname (and default archive folder name). If the
  directory on disk should differ (e.g. host is foo but you want bar/), set
  ARCHIVE_NAME.

Options:
  --dry-run, -n       rsync --dry-run
  --user, -u USER     SSH/rsync user (default: ${REMOTE_USER})
  --archive-name NAME directory under ${ARCHIVE_MOUNT} (default: same as host arg)

Environment:
  ARCHIVE_MOUNT       default ${ARCHIVE_MOUNT}
  REMOTE_USER         default ${REMOTE_USER} (or SUDO_USER when invoked via sudo)
  REMOTE_HOME_SUBDIR  default ${REMOTE_HOME_SUBDIR} — used if you omit [remote_subdir]
  SSH_OPTS            extra ssh options, e.g. "-i /path/to/key -p 22"
  RSYNC_OPTS          extra rsync args
  RSH_CMD             full ssh command for rsync -e (advanced; overrides SSH_OPTS)

Examples:
  sudo $0 goliath
  sudo $0 meta fabric-meta
  sudo $0 mail.fabric.pub
  sudo $0 mail.ericmartindale.com
  REMOTE_USER=root SSH_OPTS="-p 2222" sudo $0 legacy-host

Requires: write access to ${ARCHIVE_MOUNT} (often sudo on martindale).
USAGE
}

DRY=()
ARCHIVE_NAME=""
HOST=""
REMOTE_SUBDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    -n | --dry-run) DRY=(--dry-run); shift ;;
    -u | --user)
      REMOTE_USER="${2:?}"
      shift 2
      ;;
    --archive-name)
      ARCHIVE_NAME="${2:?}"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$HOST" ]]; then
        HOST="$1"
      elif [[ -z "$REMOTE_SUBDIR" ]]; then
        REMOTE_SUBDIR="$1"
      else
        echo "Extra argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  usage >&2
  exit 1
fi

if [[ "$HOST" == *"/"* || "$HOST" == *:* || "$HOST" == *" "* ]]; then
  echo "Host must be a simple SSH name (no / : or spaces): $HOST" >&2
  exit 1
fi

REMOTE_SUBDIR="${REMOTE_SUBDIR:-$REMOTE_HOME_SUBDIR}"
if [[ "$REMOTE_SUBDIR" == *".."* ]]; then
  echo "Invalid remote_subdir" >&2
  exit 1
fi

ARCHIVE_NAME="${ARCHIVE_NAME:-$HOST}"
DST="${ARCHIVE_MOUNT%/}/${ARCHIVE_NAME}/"

if [[ ! -d "$ARCHIVE_MOUNT" ]]; then
  echo "Archive mount missing: $ARCHIVE_MOUNT" >&2
  exit 1
fi
if [[ ! -w "$ARCHIVE_MOUNT" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Cannot write $ARCHIVE_MOUNT; use sudo or chown the mount." >&2
  exit 1
fi

mkdir -p "$DST"

# Remote path: ~/subdir/ (relative to login home) or absolute path on remote
if [[ "$REMOTE_SUBDIR" == /* ]]; then
  REMOTE_PATH="$REMOTE_SUBDIR"
else
  REMOTE_PATH="~/${REMOTE_SUBDIR#/}"
fi
REMOTE_PATH="${REMOTE_PATH//\/\//\/}"
[[ "$REMOTE_PATH" == */ ]] || REMOTE_PATH="${REMOTE_PATH}/"

SRC="${REMOTE_USER}@${HOST}:${REMOTE_PATH}"

if [[ -n "${RSH_CMD:-}" ]]; then
  RSH=(--rsh "$RSH_CMD")
else
  RSH=(--rsh "ssh -o BatchMode=no -o ConnectTimeout=30 ${SSH_OPTS:-}")
fi

# shellcheck disable=SC2206
RSYNC_EXTRA=(${RSYNC_OPTS:-})

echo "rsync ${DRY[*]} $SRC -> $DST" >&2
rsync -aH "${DRY[@]}" --info=progress2 --mkpath \
  "${RSH[@]}" \
  "${RSYNC_EXTRA[@]}" \
  "$SRC" "$DST"

echo "Done: $SRC -> $DST"
