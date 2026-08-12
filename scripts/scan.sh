#!/usr/bin/env bash
# Walk the library and convert every Dolby Vision Profile 7 MKV it finds.
# Safe to re-run: an already converted file probes as Profile 8 and is skipped.
# shellcheck shell=bash source=lib.sh source=convert.sh

# Directories that must never be touched — anything still seeding lives there,
# and rewriting a seeding file would break the torrent.
DEFAULT_EXCLUDE='downloads,remote_sync,incomplete,.recycle'

declare -A _SEEN=()

# Walking and converting run on two very different clocks. Probing a file reads
# a few hundred KB of header, so a whole library is an hour of quiet I/O and the
# cache makes every pass after the first one minutes. One 4K remux is closer to
# an hour on its own. Converting inline meant a four hour window went into two
# titles twenty files deep into the library and the walk never reached the rest
# of it — the far end of the library was never even probed.
#
# So the two are separated. The walk is not bound by the maintenance window (it
# is read-only and cheap, and it yields to the queue as it goes) and it records
# what it finds on a worklist under STATE_DIR. Conversions drain that worklist
# and *are* bound by the window. The worklist outlives the window, the process
# and the container, so a night that only manages one conversion still starts
# the next one exactly where it stopped.
_SCAN_MODE=convert
_SCAN_CONVERTED=0
_SCAN_FAILED=0

_pending_path() { printf '%s' "${STATE_DIR:-/state}/pending"; }

_pending_add() {
  local p; p="$(_pending_path)"
  [ -d "$(dirname "$p")" ] || return 0
  grep -qxF -- "$1" "$p" 2>/dev/null && return 0
  printf '%s\n' "$1" >>"$p" 2>/dev/null || true
  return 0
}

_pending_drop() {
  local p; p="$(_pending_path)"
  [ -f "$p" ] || return 0
  awk -v drop="$1" '$0 != drop' "$p" >"$p.new" 2>/dev/null && mv -f "$p.new" "$p"
  rm -f "$p.new"
  return 0
}

_pending_count() {
  local p; p="$(_pending_path)"
  [ -f "$p" ] || { echo 0; return 0; }
  awk 'NF { n++ } END { print n+0 }' "$p" 2>/dev/null || echo 0
}

# 0 -> a scheduled run must stop converting now. Manual `scan` and `report` are
# a deliberate act, so they are never cut short by the window.
_window_closed() {
  [ "$_SCAN_MODE" = scheduled ] || return 1
  is_true "${SCAN_STOP_AT_WINDOW_END:-true}" || return 1
  in_window && return 1
  return 0
}

# ------------------------------------------------------------------ convert ----
_convert_pending() {
  local p; p="$(_pending_path)"
  [ -s "$p" ] || return 0

  # Snapshot: the list is rewritten as each entry completes.
  local snap; snap="$(mktemp)"
  cp "$p" "$snap" 2>/dev/null || { rm -f "$snap"; return 0; }

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "${_WORKER_RUN:-true}" = true ] || break
    if _window_closed; then
      warn "maintenance window closed — $(num "$(_pending_count)") file(s) still on the worklist, they resume next window"
      break
    fi
    # Gone or already dealt with by the queue since the walk found it.
    [ -f "$f" ] || { _pending_drop "$f"; continue; }

    if convert_file "$f"; then
      _SCAN_CONVERTED=$((_SCAN_CONVERTED+1))
    else
      _SCAN_FAILED=$((_SCAN_FAILED+1))
    fi
    # Dropped either way. A file that failed is still Profile 7, so the next
    # walk puts it back on the list — leaving it here would head-of-line block
    # every remaining title behind the one that cannot be converted.
    _pending_drop "$f"
  done <"$snap"

  rm -f "$snap"
  return 0
}

# ------------------------------------------------------------------- walk ----
scan_paths() {
  # MODE: report | convert | scheduled
  local mode="${1:-convert}"; shift
  local -a roots=("$@")
  if [ "${#roots[@]}" -eq 0 ]; then
    local IFS=':'
    # shellcheck disable=SC2206
    roots=(${SCAN_PATHS:-/media})
    unset IFS
  fi
  _SCAN_MODE="$mode"
  _SCAN_CONVERTED=0 _SCAN_FAILED=0

  # Whatever an earlier, window-truncated run turned up goes first: it is
  # already known to need work, and the quiet hours are what it was waiting for.
  [ "$mode" = report ] || _convert_pending

  # ------------------------------------------------------------ excludes ----
  local -a prune=()
  local e
  local IFS=','
  # shellcheck disable=SC2206
  local excludes=(${SCAN_EXCLUDE-$DEFAULT_EXCLUDE})
  unset IFS
  for e in "${excludes[@]}"; do
    [ -n "$e" ] || continue
    [ "${#prune[@]}" -gt 0 ] && prune+=(-o)
    prune+=(-name "$e")
  done
  # find needs a non-empty group; -name '' never matches anything.
  [ "${#prune[@]}" -eq 0 ] && prune=(-name '')

  # --------------------------------------------------------------- cache ----
  # Remembers "this exact file was not P7" as path|size|mtime, so a nightly
  # scan over a big library re-probes only new or changed files. Entries are
  # appended as they are learned rather than written out at the end: a walk
  # that is interrupted — window, restart, SIGKILL — must not throw away the
  # hours of probing it already did.
  local cache="${STATE_DIR:-/state}/scan-cache"
  local use_cache=false
  if is_true "${SCAN_CACHE:-true}" && mkdir -p "${STATE_DIR:-/state}" 2>/dev/null; then
    use_cache=true
    _SEEN=()
    if [ -f "$cache" ]; then
      while IFS= read -r line; do [ -n "$line" ] && _SEEN["$line"]=1; done <"$cache"
      debug "scan cache: ${#_SEEN[@]} known-good entries"
    fi
  fi

  local total=0 found=0 skipped=0 cached=0 complete=true
  local root f key profile
  local fresh; fresh="$(mktemp)"
  # Probing a big library is quiet work. A heartbeat every SCAN_PROGRESS_EVERY
  # files keeps `docker logs` alive without a line per title. 0 turns it off.
  local every="${SCAN_PROGRESS_EVERY:-200}"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || { warn "scan path does not exist: $(path "$root")"; continue; }
    step "scanning $(path "$root")"

    while IFS= read -r -d '' f; do
      if [ "${_WORKER_RUN:-true}" != true ]; then complete=false; break 2; fi
      total=$((total+1))
      if [ "$every" -gt 0 ] && [ $((total % every)) -eq 0 ]; then
        info "scanned $(num "$total") files so far · $(num "$found") profile 7 · $(num "$_SCAN_CONVERTED") converted"
        # A scheduled walk owns the worker loop while it runs, so hand the
        # queue a turn rather than making an import wait for a whole library
        # sweep. A walk started from the command line has no loop to yield to.
        [ "$mode" = scheduled ] && { drain_one "${QUEUE_DIR:-/queue}" || true; }
      fi
      debug "probing $(path "$f")"
      key="$(stat -c '%n|%s|%Y' "$f" 2>/dev/null)"

      if [ "$use_cache" = true ] && [ -n "${_SEEN[$key]:-}" ]; then
        cached=$((cached+1)); printf '%s\n' "$key" >>"$fresh"; continue
      fi

      profile="$(probe_dv_profile "$f")"
      if [ "$profile" != "7" ]; then
        skipped=$((skipped+1))
        if [ "$use_cache" = true ]; then
          _SEEN["$key"]=1
          printf '%s\n' "$key" >>"$fresh"
          printf '%s\n' "$key" >>"$cache"
        fi
        continue
      fi

      found=$((found+1))
      if [ "$mode" = report ]; then
        info "profile 7: $(path "$f")  $(num "$(human "$(stat -c %s "$f")")")"
        continue
      fi
      _pending_add "$f"
    done < <(find "$root" -type d \( "${prune[@]}" \) -prune -o \
                  -type f -name '*.mkv' ! -name '.dovisionarr-*' -print0 2>/dev/null)
  done

  # Compact the cache: keep only what still exists. Only after a walk that ran
  # to the end — a truncated one has not seen the far side of the library, and
  # rewriting from it would drop everything it never reached.
  if [ "$use_cache" = true ] && [ "$complete" = true ]; then
    sort -u "$fresh" >"$cache.new" 2>/dev/null && mv -f "$cache.new" "$cache"
  fi
  rm -f "$fresh"

  if [ "$mode" = report ]; then
    ok "report: $(num "$found") profile 7 file(s) out of $(num "$total") mkv scanned"
    return 0
  fi

  _convert_pending

  ok "scan finished — $(num "$_SCAN_CONVERTED") converted, $(num "$_SCAN_FAILED") failed, $(num "$((skipped+cached))") skipped ($cached cached), $(num "$total") seen, $(num "$(_pending_count)") still queued"
  [ "$_SCAN_FAILED" -eq 0 ]
}
