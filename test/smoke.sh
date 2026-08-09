#!/usr/bin/env bash
# End to end test of the built image. Synthesises a Dolby Vision file with
# dovi_tool, runs the real pipeline over it, and checks the guarantees that
# matter: non-DV files keep their inode, converted files keep every track.
set -euo pipefail

IMAGE="${1:-dovisionarr:test}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec docker run --rm -i --entrypoint bash \
  -v "$REPO:/work:ro" -e LOG_COLOR=always -e LOG_LEVEL=debug \
  "$IMAGE" -s <<'INNER'
set -euo pipefail
export STATE_DIR=/tmp/state QUEUE_DIR=/tmp/queue
mkdir -p /tmp/state /tmp/queue /tmp/media
cd /tmp

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok — $*"; }

dv_profile() {
  ffprobe -v quiet -select_streams v:0 -print_format json -show_streams "$1" \
    | jq -r 'first(.streams[0].side_data_list[]? | select(.dv_profile!=null) | .dv_profile) // "none"'
}
n_streams() { ffprobe -v quiet -print_format json -show_streams "$1" | jq '.streams | length'; }

echo "== building fixtures =="
ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=320x240:rate=24:duration=2 -pix_fmt yuv420p10le \
       -c:v libx265 -x265-params log-level=none -f hevc bl.hevc
ffmpeg -nostdin -v error -f lavfi -i "sine=frequency=440:duration=2" -c:a flac audio.flac
printf '1\n00:00:00,000 --> 00:00:02,000\ndovisionarr\n' > subs.srt

printf '{"length":48,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}\n' > gen.json
dovi_tool generate -j gen.json -o RPU.bin >/dev/null
dovi_tool inject-rpu -i bl.hevc --rpu-in RPU.bin -o dv.hevc >/dev/null

mkvmerge -q -o /tmp/media/plain.mkv bl.hevc audio.flac subs.srt
mkvmerge -q -o /tmp/media/dv.mkv    dv.hevc audio.flac subs.srt
[ "$(dv_profile /tmp/media/dv.mkv)" = "8" ] || fail "fixture is not Dolby Vision"

echo "== a file without Profile 7 must not be touched at all =="
ln /tmp/media/plain.mkv /tmp/media/plain.hardlink.mkv
before="$(stat -c %i /tmp/media/plain.mkv)"
dovisionarr convert /tmp/media/plain.mkv
[ "$(stat -c %i /tmp/media/plain.mkv)" = "$before" ] || fail "inode changed on a non-P7 file"
[ "$(stat -c %h /tmp/media/plain.mkv)" = "2" ]       || fail "hard link was broken"
pass "inode and hard link intact"

echo "== full pipeline: extract, rewrite RPU, remux, verify, atomic replace =="
tracks_before="$(n_streams /tmp/media/dv.mkv)"
inode_before="$(stat -c %i /tmp/media/dv.mkv)"
FORCE=true dovisionarr convert /tmp/media/dv.mkv
[ "$(dv_profile /tmp/media/dv.mkv)" = "8" ]            || fail "output lost its Dolby Vision metadata"
[ "$(n_streams /tmp/media/dv.mkv)" = "$tracks_before" ] || fail "tracks were dropped"
[ "$(stat -c %i /tmp/media/dv.mkv)" != "$inode_before" ] || fail "file was not replaced"
pass "converted, $tracks_before tracks preserved, replaced atomically"

echo "== DRY_RUN writes nothing =="
inode_before="$(stat -c %i /tmp/media/dv.mkv)"
FORCE=true DRY_RUN=true dovisionarr convert /tmp/media/dv.mkv
[ "$(stat -c %i /tmp/media/dv.mkv)" = "$inode_before" ] || fail "DRY_RUN modified the file"
pass "nothing written"

echo "== the Sonarr/Radarr hook =="
sonarr_eventtype=Test DOVISIONARR_QUEUE=/tmp/queue /work/enqueue.sh >/dev/null
sonarr_eventtype=Download sonarr_episodefile_path=/tmp/media/dv.mkv \
  DOVISIONARR_QUEUE=/tmp/queue /work/enqueue.sh >/dev/null
compgen -G "/tmp/queue/*.job" >/dev/null || fail "hook did not queue the file"
pass "job queued"

echo "== scan and report =="
dovisionarr report /tmp/media
dovisionarr scan /tmp/media
pass "scan completed"

echo
echo "all smoke tests passed"
INNER
