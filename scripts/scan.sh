#!/usr/bin/env bash
# Walk the library and convert every Dolby Vision Profile 7 MKV it finds.
# Safe to re-run: an already converted file probes as Profile 8 and is skipped.
# shellcheck shell=bash source=lib.sh source=convert.sh

# Directories that must never be touched — anything still seeding lives there,
# and rewriting a seeding file would break the torrent.
DEFAULT_EXCLUDE='downloads,remote_sync,incomplete,.recycle'

declare -A _SEEN=()

scan_paths() {
  local report_only="$1"; shift
  local -a roots=("$@")
  if [ "${#roots[@]}" -eq 0 ]; then
    local IFS=':'
    # shellcheck disable=SC2206
    roots=(${SCAN_PATHS:-/media})
  fi

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
  # scan over a big library re-probes only new or changed files.
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

  local total=0 found=0 converted=0 failed=0 skipped=0 cached=0
  local root f key profile
  local fresh; fresh="$(mktemp)"
  # Probing a big library is quiet work. A heartbeat every SCAN_PROGRESS_EVERY
  # files keeps `docker logs` alive without a line per title. 0 turns it off.
  local every="${SCAN_PROGRESS_EVERY:-200}"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || { warn "scan path does not exist: $(path "$root")"; continue; }
    step "scanning $(path "$root")"

    while IFS= read -r -d '' f; do
      total=$((total+1))
      if [ "$every" -gt 0 ] && [ $((total % every)) -eq 0 ]; then
        info "scanned $(num "$total") files so far · $(num "$found") profile 7 · $(num "$converted") converted"
      fi
      debug "probing $(path "$f")"
      key="$(stat -c '%n|%s|%Y' "$f" 2>/dev/null)"

      if [ "$use_cache" = true ] && [ -n "${_SEEN[$key]:-}" ]; then
        cached=$((cached+1)); printf '%s\n' "$key" >>"$fresh"; continue
      fi

      profile="$(probe_dv_profile "$f")"
      if [ "$profile" != "7" ]; then
        skipped=$((skipped+1))
        [ "$use_cache" = true ] && printf '%s\n' "$key" >>"$fresh"
        continue
      fi

      found=$((found+1))
      if is_true "$report_only"; then
        info "profile 7: $(path "$f")  $(num "$(human "$(stat -c %s "$f")")")"
        continue
      fi

      # A scheduled scan is bound to its maintenance window; stop on the edge.
      if is_true "${SCAN_ENABLED:-false}" && is_true "${SCAN_STOP_AT_WINDOW_END:-true}" \
         && ! in_window; then
        warn "maintenance window closed — pausing scan, it resumes next window"
        break 2
      fi

      if convert_file "$f"; then converted=$((converted+1)); else failed=$((failed+1)); fi
    done < <(find "$root" -type d \( "${prune[@]}" \) -prune -o -type f -name '*.mkv' -print0 2>/dev/null)
  done

  # Compact the cache: keep only what still exists.
  if [ "$use_cache" = true ]; then
    sort -u "$fresh" >"$cache.new" 2>/dev/null && mv -f "$cache.new" "$cache"
  fi
  rm -f "$fresh"

  if is_true "$report_only"; then
    ok "report: $(num "$found") profile 7 file(s) out of $(num "$total") mkv scanned"
  else
    ok "scan finished — $(num "$converted") converted, $(num "$failed") failed, $(num "$((skipped+cached))") skipped ($cached cached), $(num "$total") seen"
  fi
  [ "$failed" -eq 0 ]
}
