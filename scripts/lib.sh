#!/usr/bin/env bash
# Shared helpers: logging, colours, probing, small utilities.
# shellcheck shell=bash

DOVISIONARR_VERSION="${DOVISIONARR_VERSION:-dev}"

# ---------------------------------------------------------------- colours ----
# LOG_COLOR = auto | always | never.  NO_COLOR=1 also turns colour off.
# "auto" keeps colour on even without a TTY, because `docker logs` renders
# ANSI just fine and that is where these logs are read from.
if [ "${LOG_COLOR:-auto}" = "never" ] || [ -n "${NO_COLOR:-}" ]; then
  C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_BOLD=''
else
  C_RESET=$'\033[0m'  C_DIM=$'\033[2m'     C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'   C_GREEN=$'\033[32m'  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'  C_MAGENTA=$'\033[35m' C_CYAN=$'\033[36m'
fi

# LOG_LEVEL = debug | info | warn | error
_level_num() {
  case "$1" in
    debug) echo 10 ;; info) echo 20 ;; warn) echo 30 ;; error) echo 40 ;; *) echo 20 ;;
  esac
}
_LOG_MIN="$(_level_num "${LOG_LEVEL:-info}")"

_log() {
  local level="$1" colour="$2" label="$3"; shift 3
  [ "$(_level_num "$level")" -ge "$_LOG_MIN" ] || return 0
  printf '%s%s%s %s%-5s%s %s\n' \
    "$C_DIM" "$(date '+%H:%M:%S')" "$C_RESET" \
    "$colour" "$label" "$C_RESET" "$*" >&2
}

debug() { _log debug "$C_DIM"     "debug" "$@"; }
info()  { _log info  "$C_BLUE"    "info"  "$@"; }
warn()  { _log warn  "$C_YELLOW"  "warn"  "$@"; }
error() { _log error "$C_RED$C_BOLD" "error" "$@"; }
ok()    { _log info  "$C_GREEN"   "ok"    "$@"; }
step()  { _log info  "$C_MAGENTA" "step"  "$@"; }

# Inline highlights, for paths / numbers inside a message.
path()  { printf '%s%s%s' "$C_CYAN" "$1" "$C_RESET"; }
num()   { printf '%s%s%s' "$C_BOLD" "$1" "$C_RESET"; }

banner() {
  printf '%s' "$C_CYAN$C_BOLD" >&2
  cat >&2 <<'ART'
        _     _
 __   _(_)___(_) ___  _ __   __ _ _ __ _ __
 \ \ / / / __| |/ _ \| '_ \ / _` | '__| '__|
  \ V /| \__ \ | (_) | | | | (_| | |  | |
   \_/ |_|___/_|\___/|_| |_|\__,_|_|  |_|
ART
  printf '%s' "$C_RESET" >&2
  info "dovisionarr $(num "$DOVISIONARR_VERSION")  ·  Dolby Vision Profile 7 → 8.1"
}

# ------------------------------------------------------------------ utils ----
is_true() { case "${1,,}" in 1|true|yes|on|enabled) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- scratch ----
# The image creates /queue, /state and /media but never /scratch, so a /scratch
# that exists is one Docker made for a bind mount. Mounting the disk is the
# whole configuration: SCRATCH_DIR still wins when set, and with no mount at all
# the base layer is written next to the media file as before.
DEFAULT_SCRATCH_DIR="${DEFAULT_SCRATCH_DIR:-/scratch}"
_SCRATCH_AUTO=false
if [ -z "${SCRATCH_DIR:-}" ] && [ -d "$DEFAULT_SCRATCH_DIR" ]; then
  SCRATCH_DIR="$DEFAULT_SCRATCH_DIR"
  _SCRATCH_AUTO=true
  export SCRATCH_DIR
fi

# Heavy tools run de-prioritised so the host stays responsive mid-conversion.
LOWPRIO=(nice -n "${NICE:-10}")
if [ "${IONICE:-true}" != "false" ] && command -v ionice >/dev/null 2>&1; then
  LOWPRIO=(ionice -c "${IONICE_CLASS:-2}" -n "${IONICE_LEVEL:-7}" "${LOWPRIO[@]}")
fi

human() {  # bytes -> human readable
  numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1}B"
}

elapsed() {  # seconds -> 1h02m03s
  local s="$1"
  printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# -------------------------------------------------------- path translation ----
# Sonarr and Radarr queue the path *they* see. When dovisionarr mounts the same
# media somewhere else — /library1 there, /media here — that path resolves to
# nothing and every queued job is dropped. PATH_MAP fixes it explicitly, and a
# suffix search against SCAN_PATHS catches the setups that never set it.
#
#   PATH_MAP="/library1:/media"                   one mapping
#   PATH_MAP="/library1:/media,/tv:/media/TV"     several, first match wins

# map_path PATH -> PATH with PATH_MAP applied, unchanged when nothing matches
map_path() {
  local p="$1" pair from to
  local IFS=','
  # shellcheck disable=SC2206
  local pairs=(${PATH_MAP:-})
  unset IFS
  for pair in "${pairs[@]}"; do
    [ -n "$pair" ] || continue
    from="${pair%%:*}"; to="${pair#*:}"
    from="${from%/}"; to="${to%/}"
    if [ -z "$from" ] || [ -z "$to" ]; then continue; fi
    case "$p" in
      "$from"/*) printf '%s\n' "$to/${p#"$from"/}"; return 0 ;;
      "$from")   printf '%s\n' "$to"; return 0 ;;
    esac
  done
  printf '%s\n' "$p"
}

# find_by_suffix PATH -> an existing file under one of SCAN_PATHS whose trailing
# components match PATH. One leading component is dropped at a time, so
# /library1/Films/A/B.mkv is tried as <root>/Films/A/B.mkv, then <root>/A/B.mkv.
find_by_suffix() {
  local p="$1" root rest cand
  local IFS=':'
  # shellcheck disable=SC2206
  local roots=(${SCAN_PATHS:-/media})
  unset IFS
  rest="${p#/}"
  while [ -n "$rest" ]; do
    for root in "${roots[@]}"; do
      cand="${root%/}/$rest"
      if [ "$cand" != "$p" ] && [ -f "$cand" ]; then
        printf '%s\n' "$cand"; return 0
      fi
    done
    case "$rest" in */*) rest="${rest#*/}" ;; *) break ;; esac
  done
  return 1
}

# resolve_media_path PATH -> a path that exists in this container, or nothing.
# Written without trailing `&&` lists so it stays safe to call under `set -e`.
resolve_media_path() {
  local p="$1" m
  if [ -z "$p" ]; then return 1; fi
  if [ -f "$p" ]; then printf '%s\n' "$p"; return 0; fi

  m="$(map_path "$p")"
  if [ "$m" != "$p" ] && [ -f "$m" ]; then printf '%s\n' "$m"; return 0; fi

  if is_true "${PATH_MAP_AUTO:-true}"; then
    if m="$(find_by_suffix "$p")"; then printf '%s\n' "$m"; return 0; fi
  fi
  return 1
}

# ------------------------------------------------------------------ probe ----
# Everything below reads only the file header, so probing a whole library is
# cheap: a few hundred KB per title, not a full read.

# probe_dv_profile FILE -> "7" | "8" | "5" | "none"
probe_dv_profile() {
  ffprobe -v quiet -select_streams v:0 -print_format json -show_streams "$1" 2>/dev/null \
    | jq -r 'first(.streams[0].side_data_list[]? | select(.dv_profile != null) | .dv_profile) // "none"'
}

# probe_json FILE -> compact json with the fields the pipeline needs
probe_json() {
  ffprobe -v quiet -print_format json -show_streams -show_format "$1" 2>/dev/null | jq -c '
    {
      duration:  (.format.duration // "0" | tonumber),
      video:     ([.streams[] | select(.codec_type=="video")]     | length),
      audio:     ([.streams[] | select(.codec_type=="audio")]     | length),
      subtitle:  ([.streams[] | select(.codec_type=="subtitle")]  | length),
      codec:     (first(.streams[] | select(.codec_type=="video") | .codec_name) // ""),
      r_rate:    (first(.streams[] | select(.codec_type=="video") | .r_frame_rate)   // "0/0"),
      avg_rate:  (first(.streams[] | select(.codec_type=="video") | .avg_frame_rate) // "0/0"),
      lang:      (first(.streams[] | select(.codec_type=="video") | .tags.language)  // ""),
      dv:        (first(.streams[] | select(.codec_type=="video")
                        | .side_data_list[]? | select(.dv_profile != null)) // null)
    }'
}

# free_bytes PATH -> available bytes on the filesystem holding PATH
free_bytes() {
  df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# --------------------------------------------------------- maintenance window ----
# SCAN_WINDOW="02:00-06:00", wrapping past midnight ("22:00-04:00") is fine.
# SCAN_DAYS="*" or a comma list of mon,tue,wed,thu,fri,sat,sun.

_hhmm() { echo $(( 10#${1%%:*} * 60 + 10#${1##*:} )); }

# in_window -> true when now is inside SCAN_WINDOW on an allowed day
in_window() {
  local spec="${SCAN_WINDOW:-00:00-23:59}"
  local days="${SCAN_DAYS:-*}"

  if [ "$days" != "*" ]; then
    local today; today="$(date +%a)"; today="${today,,}"
    case ",${days,,}," in *",$today,"*) ;; *) return 1 ;; esac
  fi

  local start end now
  start="$(_hhmm "${spec%%-*}")"
  end="$(_hhmm "${spec##*-}")"
  now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))

  if [ "$start" -le "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else                                  # window crosses midnight
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

# window_id -> a token that changes once per window occurrence, so a scheduled
# scan runs once per window instead of restarting every poll.
window_id() {
  local spec="${SCAN_WINDOW:-00:00-23:59}"
  local start end now
  start="$(_hhmm "${spec%%-*}")"; end="$(_hhmm "${spec##*-}")"
  now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  # A wrapping window that we entered before midnight belongs to the day it started.
  if [ "$start" -gt "$end" ] && [ "$now" -lt "$end" ]; then
    date -d yesterday +%F
  else
    date +%F
  fi
}
