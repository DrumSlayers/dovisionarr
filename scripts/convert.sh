#!/usr/bin/env bash
# Convert one MKV from Dolby Vision Profile 7 to single-layer Profile 8.1.
# No re-encode. Every audio track, subtitle, chapter and attachment is kept.
# A file that is not P7 is never opened for writing, so its hard links survive.
# shellcheck shell=bash source=lib.sh

_CV_BL='' _CV_TMP='' _CV_LOCKFD=''

_convert_cleanup() {
  [ -n "$_CV_BL"  ] && rm -f -- "$_CV_BL"
  [ -n "$_CV_TMP" ] && rm -f -- "$_CV_TMP"
  [ -n "$_CV_LOCKFD" ] && exec {_CV_LOCKFD}>&-
  _CV_BL='' _CV_TMP='' _CV_LOCKFD=''
  return 0
}

convert_file() {
  local src="$1"
  local started; started="$(date +%s)"
  trap _convert_cleanup RETURN

  [ -f "$src" ] || { error "not a file: $(path "$src")"; return 1; }
  case "$src" in
    *.mkv) ;;
    *) debug "skip, not an mkv: $(path "$src")"; return 0 ;;
  esac
  case "$(basename "$src")" in
    .dovisionarr-*) debug "skip, own temp file: $(path "$src")"; return 0 ;;
  esac

  # ---------------------------------------------------------------- probe ----
  local meta profile el compat
  meta="$(probe_json "$src")"
  [ -n "$meta" ] || { error "ffprobe returned nothing for $(path "$src")"; return 1; }
  profile="$(jq -r '.dv.dv_profile // "none"'                <<<"$meta")"
  el="$(jq -r      '.dv.el_present_flag // 0'                <<<"$meta")"
  compat="$(jq -r  '.dv.dv_bl_signal_compatibility_id // "-"' <<<"$meta")"

  if [ "$profile" != "7" ] && ! is_true "${FORCE:-false}"; then
    debug "skip, dv profile $profile: $(path "$(basename "$src")")"
    return 0
  fi

  # Conversions are disk bound, so only one runs at a time across the whole
  # container: worker, scheduled scan and a manual `docker exec` all queue up
  # behind this lock instead of thrashing the array.
  # Note: no redirection may be attached to this `exec` — without a command it
  # would rewire the whole shell's descriptors, not just this one.
  mkdir -p "${STATE_DIR:-/state}" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1 && [ -w "${STATE_DIR:-/state}" ]; then
    exec {_CV_LOCKFD}>"${STATE_DIR:-/state}/convert.lock"
    flock "$_CV_LOCKFD"
  fi

  local size; size="$(stat -c %s "$src")"
  step "P7 → P8.1  $(path "$(basename "$src")")"
  info "  source $(num "$(human "$size")")  ·  dv profile $(num "$profile")  ·  el=$el  ·  bl_compat=$compat"

  if is_true "${DRY_RUN:-false}"; then
    warn "  DRY_RUN is on — nothing written"
    return 0
  fi

  # ------------------------------------------------------------ preflight ----
  local dst_dir scratch_dir
  dst_dir="$(dirname "$src")"
  scratch_dir="${SCRATCH_DIR:-$dst_dir}"
  mkdir -p "$scratch_dir" 2>/dev/null || true
  [ -w "$scratch_dir" ] || { error "  scratch dir not writable: $(path "$scratch_dir")"; return 1; }
  [ -w "$dst_dir" ]     || { error "  media dir not writable: $(path "$dst_dir")"; return 1; }

  # The base layer is the source minus the enhancement layer; the remux is
  # roughly the source. Ask for a little more than that on each filesystem.
  local need_scratch=$(( size * 9 / 10 )) need_dst=$(( size * 11 / 10 ))
  if [ "$(free_bytes "$scratch_dir")" -lt "$need_scratch" ]; then
    error "  not enough free space on scratch $(path "$scratch_dir"), need ~$(human "$need_scratch")"
    return 1
  fi
  if [ "$(free_bytes "$dst_dir")" -lt "$need_dst" ]; then
    error "  not enough free space next to the media, need ~$(human "$need_dst")"
    return 1
  fi

  _CV_BL="$(mktemp -p "$scratch_dir" .dovisionarr-bl-XXXXXX.hevc)"
  _CV_TMP="$(mktemp -p "$dst_dir"    .dovisionarr-out-XXXXXX.mkv)"

  # ------------------------------------------------ extract + rewrite RPU ----
  # One pass over the source. ffmpeg lifts the HEVC elementary stream out of
  # the Matroska container and pipes it straight into dovi_tool, so the
  # dual-layer stream never lands on disk.
  info "  extracting base layer, rewriting RPU to 8.1 (mode 2, EL discarded)"
  if ! ( set -o pipefail
         "${LOWPRIO[@]}" ffmpeg -nostdin -v error \
             -i "$src" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - \
           | "${LOWPRIO[@]}" dovi_tool -m 2 convert --discard - -o "$_CV_BL" >/dev/null ); then
    error "  base layer extraction failed"
    return 1
  fi
  [ -s "$_CV_BL" ] || { error "  dovi_tool produced an empty base layer"; return 1; }
  info "  base layer $(num "$(human "$(stat -c %s "$_CV_BL")")")"

  # ---------------------------------------------------------------- remux ----
  # mkvmerge takes the new video track plus everything else from the source
  # (-D drops the source's own video track).
  local -a mkvargs=(--quiet --output "$_CV_TMP")

  # A raw elementary stream carries no container timing. mkvmerge reads the
  # frame rate from the SPS VUI, but pass the source's rate explicitly so a
  # stream without VUI timing can never silently land on mkvmerge's 25 fps
  # default and desync every audio track.
  local r_rate avg_rate vlang
  r_rate="$(jq -r '.r_rate' <<<"$meta")"
  avg_rate="$(jq -r '.avg_rate' <<<"$meta")"
  if [ "$r_rate" = "$avg_rate" ] && [ "$r_rate" != "0/0" ]; then
    mkvargs+=(--default-duration "0:${r_rate}fps")
  else
    warn "  variable frame rate ($r_rate vs $avg_rate) — letting mkvmerge derive timing"
  fi
  vlang="$(jq -r '.lang' <<<"$meta")"
  [ -n "$vlang" ] && mkvargs+=(--language "0:$vlang")
  mkvargs+=("$_CV_BL" -D "$src")

  info "  remuxing with all audio, subtitles, chapters and attachments"
  if ! "${LOWPRIO[@]}" mkvmerge "${mkvargs[@]}"; then
    error "  mkvmerge failed"
    return 1
  fi

  # --------------------------------------------------------------- verify ----
  # Nothing is replaced until the new file has been proven good.
  local newmeta newprofile newcompat a b k
  newmeta="$(probe_json "$_CV_TMP")"
  newprofile="$(jq -r '.dv.dv_profile // "none"' <<<"$newmeta")"
  newcompat="$(jq -r '.dv.dv_bl_signal_compatibility_id // "-"' <<<"$newmeta")"

  if [ "$newprofile" != "8" ]; then
    error "  output is dv profile $newprofile, expected 8 — original kept"
    return 1
  fi
  [ "$newcompat" = "1" ] || warn "  output bl_signal_compatibility_id is $newcompat, expected 1"

  for k in audio subtitle; do
    a="$(jq -r ".$k" <<<"$meta")"; b="$(jq -r ".$k" <<<"$newmeta")"
    if [ "$a" != "$b" ]; then
      error "  $k track count changed ($a → $b) — original kept"
      return 1
    fi
  done

  local d1 d2 delta
  d1="$(jq -r '.duration|floor' <<<"$meta")"
  d2="$(jq -r '.duration|floor' <<<"$newmeta")"
  delta=$(( d1 > d2 ? d1 - d2 : d2 - d1 ))
  if [ "$delta" -gt "${MAX_DURATION_DRIFT:-2}" ]; then
    error "  duration drifted by ${delta}s (${d1}s → ${d2}s) — original kept"
    return 1
  fi

  # -------------------------------------------------------------- replace ----
  # Match the original's ownership and permissions, then rename over it. Same
  # filesystem, so this is one atomic rename(2): a reader sees either the old
  # file or the new one, never a half-written mix.
  chmod --reference="$src" "$_CV_TMP" 2>/dev/null || true
  chown --reference="$src" "$_CV_TMP" 2>/dev/null || true
  if is_true "${PRESERVE_MTIME:-true}"; then touch -r "$src" "$_CV_TMP"; fi

  local newsize; newsize="$(stat -c %s "$_CV_TMP")"
  mv -f -- "$_CV_TMP" "$src"
  _CV_TMP=''

  local took=$(( $(date +%s) - started ))
  ok "converted in $(elapsed "$took")  ·  $(human "$size") → $(num "$(human "$newsize")")  ·  $(path "$(basename "$src")")"
  return 0
}
