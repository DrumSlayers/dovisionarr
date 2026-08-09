#!/usr/bin/env bash
# Drop to PUID/PGID (the usual *arr convention) and hand over to the CLI.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
QUEUE="${QUEUE_DIR:-/queue}"

# Publish the *arr hook into the shared queue directory, so Sonarr and Radarr
# only ever need the one queue mount and always run the hook that matches this
# image. The worker only ever looks at *.job, so it ignores this file.
if [ -w "$QUEUE" ]; then
  install -m0755 /opt/dovisionarr/enqueue.sh "$QUEUE/enqueue.sh" 2>/dev/null \
    || echo "dovisionarr: could not publish enqueue.sh into $QUEUE" >&2
fi

if [ "$(id -u)" = "0" ] && [ "$PUID" != "0" ]; then
  groupmod -o -g "$PGID" dovisionarr
  usermod  -o -u "$PUID" -g "$PGID" dovisionarr
  # Only the container's own directories — never the media mount.
  chown -R dovisionarr:dovisionarr "$QUEUE" "${STATE_DIR:-/state}" 2>/dev/null || true
  exec gosu dovisionarr "$0" "$@"
fi

exec /opt/dovisionarr/dovisionarr "$@"
