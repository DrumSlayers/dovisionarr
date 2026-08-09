#!/usr/bin/env bash
# Long running worker: drains the job queue that Sonarr/Radarr write into,
# and optionally runs a full library scan inside a maintenance window.
# One conversion at a time — this workload is disk bound, not CPU bound.
# shellcheck shell=bash source=lib.sh source=convert.sh source=scan.sh

run_worker() {
  local queue="${QUEUE_DIR:-/queue}"
  local state="${STATE_DIR:-/state}"
  mkdir -p "$queue" "$queue/failed" "$state"

  banner
  info "queue      $(path "$queue")  (poll every ${POLL_INTERVAL:-15}s)"
  info "scratch    $(path "${SCRATCH_DIR:-<next to each media file>}")"
  if is_true "${SCAN_ENABLED:-false}"; then
    info "scan       $(num "enabled")  ·  ${SCAN_PATHS:-/media}  ·  window ${SCAN_WINDOW:-02:00-06:00} on ${SCAN_DAYS:-*}"
  else
    info "scan       disabled (set SCAN_ENABLED=true to sweep the library on a schedule)"
  fi
  is_true "${DRY_RUN:-false}" && warn "DRY_RUN is on — nothing will be written"

  # Heartbeat for the container healthcheck, kept ticking during a conversion
  # that can easily run for an hour on a large remux.
  ( while :; do date +%s >"$state/heartbeat"; sleep 30; done ) &
  local hb=$!

  local running=true
  # shellcheck disable=SC2064
  trap "running=false; kill $hb 2>/dev/null" TERM INT

  while [ "$running" = true ]; do
    drain_queue "$queue"
    maybe_scheduled_scan "$state"
    sleep "${POLL_INTERVAL:-15}" &
    wait $! 2>/dev/null || true
  done
  kill "$hb" 2>/dev/null || true
  info "worker stopped"
}

# ------------------------------------------------------------------ queue ----
drain_queue() {
  local queue="$1" job target
  for job in "$queue"/*.job; do
    [ -e "$job" ] || continue

    # Claim the job by renaming it, so a restart mid-conversion cannot run the
    # same file twice and a crash leaves an obvious .running file behind.
    local claim="${job%.job}.running"
    mv -n "$job" "$claim" 2>/dev/null || continue
    [ -f "$claim" ] || continue

    target="$(head -n1 "$claim")"
    if [ -z "$target" ] || [ ! -f "$target" ]; then
      warn "queued file is gone, dropping job: $(path "${target:-<empty>}")"
      rm -f "$claim"; continue
    fi

    info "picked up from queue: $(path "$(basename "$target")")"
    if convert_file "$target"; then
      rm -f "$claim"
    else
      mv -f "$claim" "$queue/failed/$(basename "${claim%.running}").job"
      error "moved to $(path "$queue/failed") — re-queue it by moving the file back"
    fi
  done
}

# --------------------------------------------------------- scheduled scan ----
maybe_scheduled_scan() {
  local state="$1"
  is_true "${SCAN_ENABLED:-false}" || return 0
  in_window || return 0

  local id marker
  id="$(window_id)"
  marker="$state/last-scan"
  [ -f "$marker" ] && [ "$(cat "$marker")" = "$id" ] && return 0

  step "maintenance window open — starting library scan"
  scan_paths false || true
  printf '%s\n' "$id" >"$marker"
}
