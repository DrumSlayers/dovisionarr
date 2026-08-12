#!/usr/bin/env bash
# Long running worker: drains the job queue that Sonarr/Radarr write into,
# and optionally runs a full library scan inside a maintenance window.
# One conversion at a time — this workload is disk bound, not CPU bound.
# shellcheck shell=bash source=lib.sh source=convert.sh source=scan.sh

_WORKER_RUN=true

_worker_stop() {
  _WORKER_RUN=false
  warn "shutdown requested — finishing the current step and stopping"
}

run_worker() {
  local queue="${QUEUE_DIR:-/queue}"
  local state="${STATE_DIR:-/state}"
  mkdir -p "$queue" "$queue/failed" "$state"

  banner
  info "queue      $(path "$queue")  (poll every ${POLL_INTERVAL:-15}s)"
  if [ -n "${SCRATCH_DIR:-}" ]; then
    info "scratch    $(path "$SCRATCH_DIR")$([ "${_SCRATCH_AUTO:-false}" = true ] && printf ' (detected mount)')"
  else
    info "scratch    next to each media file (mount a disk at $(path "$DEFAULT_SCRATCH_DIR") to move it)"
  fi
  if is_true "${SCAN_ENABLED:-false}"; then
    info "scan       $(num "enabled")  ·  ${SCAN_PATHS:-/media}  ·  conversions in window ${SCAN_WINDOW:-02:00-06:00} on ${SCAN_DAYS:-*}"
  else
    info "scan       disabled (set SCAN_ENABLED=true to sweep the library on a schedule)"
  fi
  is_true "${DRY_RUN:-false}" && warn "DRY_RUN is on — nothing will be written"

  # Startup is the one moment where no conversion of ours can be in flight, so
  # it is the only safe place to clean up after a kill.
  reclaim_orphan_jobs "$queue"
  sweep_stale_temps

  # Heartbeat for the container healthcheck, kept ticking during a conversion
  # that can easily run for an hour on a large remux.
  ( while :; do date +%s >"$state/heartbeat"; sleep 30; done ) &
  local hb=$!

  # tini runs with -g, so a `docker stop` reaches ffmpeg, dovi_tool and
  # mkvmerge too: the pipeline below fails fast instead of being SIGKILLed
  # halfway, which is what lets the cleanup traps run at all.
  # shellcheck disable=SC2064
  trap "_worker_stop; kill $hb 2>/dev/null" TERM INT
  # shellcheck disable=SC2064
  trap "_convert_cleanup; kill $hb 2>/dev/null" EXIT

  while [ "$_WORKER_RUN" = true ]; do
    local worked=false
    drain_one "$queue" && worked=true
    [ "$_WORKER_RUN" = true ] || break

    # After every single job, not after the whole queue. A run of imports used
    # to hold this loop for hours, and the maintenance window could open and
    # close again without the scan ever getting a look at the clock.
    maybe_scheduled_scan "$state"

    if [ "$worked" != true ]; then
      sleep "${POLL_INTERVAL:-15}" &
      wait $! 2>/dev/null || true
    fi
  done
  kill "$hb" 2>/dev/null || true
  info "worker stopped"
}

# ------------------------------------------------------------------ queue ----
# A .running file is a job that was claimed and never finished, because the
# container was killed mid-conversion. Nothing else ever looks at one again, so
# without this the job is simply lost.
reclaim_orphan_jobs() {
  local queue="$1" claim n=0
  for claim in "$queue"/*.running; do
    [ -e "$claim" ] || continue
    mv -f "$claim" "${claim%.running}.job" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && warn "re-queued $(num "$n") job(s) left behind by an earlier shutdown"
  return 0
}

# Handles at most one job and returns 0 when it did, so the caller keeps
# control between conversions.
drain_one() {
  local queue="$1" job claim queued target
  for job in "$queue"/*.job; do
    [ -e "$job" ] || continue

    # Claim the job by renaming it, so a restart mid-conversion cannot run the
    # same file twice and a crash leaves an obvious .running file behind.
    claim="${job%.job}.running"
    mv -n "$job" "$claim" 2>/dev/null || continue
    [ -f "$claim" ] || continue

    # Sonarr and Radarr queue the path they see, which is not always the path
    # this container sees. PATH_MAP and the suffix search sort that out.
    queued="$(head -n1 "$claim")"
    target="$(resolve_media_path "$queued")" || target=''
    if [ -z "$target" ]; then
      warn "queued file is gone, dropping job: $(path "${queued:-<empty>}")"
      if [ -n "$queued" ]; then
        local top root
        top="${queued#/}"; top="/${top%%/*}"
        root="${SCAN_PATHS:-/media}"; root="${root%%:*}"
        [ -d "$top" ] || warn "  $(path "$top") does not exist in this container — mount your media at the same path Sonarr/Radarr use, or set PATH_MAP=\"$top:$root\""
      fi
      rm -f "$claim"; return 0
    fi
    [ "$target" != "$queued" ] && \
      info "queued path remapped: $(path "$queued") → $(path "$target")"

    # Debug: most queued files turn out not to be P7. convert_file prints an
    # info line as soon as there is something to convert.
    debug "picked up from queue: $(path "$(basename "$target")")"
    if convert_file "$target"; then
      rm -f "$claim"
    else
      mv -f "$claim" "$queue/failed/$(basename "${claim%.running}").job"
      error "moved to $(path "$queue/failed") — re-queue it by moving the file back"
    fi
    return 0
  done
  return 1
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
  scan_paths scheduled || true

  # Only claim the window once the worklist is actually empty. A window that
  # ran out of hours mid-worklist has to be allowed to pick it up again.
  if [ "$(_pending_count)" -eq 0 ]; then
    printf '%s\n' "$id" >"$marker"
  else
    info "$(num "$(_pending_count)") file(s) left for the next window"
  fi
}
