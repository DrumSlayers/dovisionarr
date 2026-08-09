#!/bin/sh
# dovisionarr enqueue hook — Sonarr / Radarr "Custom Script" connection.
#
# Bind-mount this file into the *arr container and point the Custom Script at
# it. It is plain POSIX sh with no dependencies, so nothing has to be installed
# inside Sonarr or Radarr and an image update can never break it.
#
# All it does is drop the path of each imported file into the shared queue
# directory. The dovisionarr worker picks it up from there.
set -eu

QUEUE="${DOVISIONARR_QUEUE:-/queue}"

EVENT="${radarr_eventtype:-${sonarr_eventtype:-}}"

case "$EVENT" in
  Test)
    mkdir -p "$QUEUE" 2>/dev/null || true
    if [ -w "$QUEUE" ]; then
      echo "dovisionarr: queue $QUEUE is writable — hook OK"
      exit 0
    fi
    echo "dovisionarr: queue $QUEUE is NOT writable from this container" >&2
    exit 1
    ;;
  Download|Upgrade) ;;      # import of a new or upgraded file
  *) exit 0 ;;
esac

mkdir -p "$QUEUE"
STAMP="$(date +%s)-$$"
N=0

enqueue() {
  [ -n "${1:-}" ] || return 0
  case "$1" in *.mkv|*.MKV) ;; *) return 0 ;; esac
  N=$((N + 1))
  # Write, then rename: the worker only ever sees a complete job file.
  printf '%s\n' "$1" > "$QUEUE/.tmp-$STAMP-$N"
  mv "$QUEUE/.tmp-$STAMP-$N" "$QUEUE/$STAMP-$N.job"
  echo "dovisionarr: queued $1"
}

enqueue "${radarr_moviefile_path:-}"
enqueue "${sonarr_episodefile_path:-}"

# Season packs arrive as one pipe-separated list.
if [ -n "${sonarr_episodefile_paths:-}" ]; then
  OLDIFS="$IFS"; IFS='|'
  for p in $sonarr_episodefile_paths; do enqueue "$p"; done
  IFS="$OLDIFS"
fi

exit 0
