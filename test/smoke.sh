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

# Two ffmpegs live in the test image and the distinction is the point.
#   /usr/local/bin  the stripped-down build that ships: demux Matroska, rewrite
#                   HEVC to Annex-B, probe. No encoders, no lavfi, no network.
#   /usr/bin        Debian's full build, present only in the --target test
#                   stage, used to synthesise fixtures and nothing else.
# Every assertion below goes through the shipped binaries.
FIXTURE_FFMPEG=/usr/bin/ffmpeg
PROBE=/usr/local/bin/ffprobe

dv_profile() {
  "$PROBE" -v quiet -select_streams v:0 -print_format json -show_streams "$1" \
    | jq -r 'first(.streams[0].side_data_list[]? | select(.dv_profile!=null) | .dv_profile) // "none"'
}
n_streams() { "$PROBE" -v quiet -print_format json -show_streams "$1" | jq '.streams | length'; }

echo "== the shipped ffmpeg is the minimal build =="
[ "$(command -v ffmpeg)"  = /usr/local/bin/ffmpeg  ] || fail "PATH does not resolve to the shipped ffmpeg"
[ "$(command -v ffprobe)" = /usr/local/bin/ffprobe ] || fail "PATH does not resolve to the shipped ffprobe"
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' libx265 '; then
  fail "shipped ffmpeg carries encoders"
fi
pass "no encoders, resolves ahead of the fixture build"

echo "== building fixtures =="
"$FIXTURE_FFMPEG" -nostdin -v error -f lavfi -i testsrc2=size=320x240:rate=24:duration=2 -pix_fmt yuv420p10le \
       -c:v libx265 -x265-params log-level=none -f hevc bl.hevc
"$FIXTURE_FFMPEG" -nostdin -v error -f lavfi -i "sine=frequency=440:duration=2" -c:a flac audio.flac
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

echo "== a queued path from a different mount point is still found =="
# The single most common misconfiguration: Radarr mounts the library at
# /library1, dovisionarr at /media, and every queued job points at a path that
# does not exist here.
mkdir -p /tmp/media/Films/Fixture
cp /tmp/media/plain.mkv /tmp/media/Films/Fixture/f.mkv
# shellcheck source=../scripts/lib.sh
. /opt/dovisionarr/lib.sh
export SCAN_PATHS=/tmp/media
[ "$(resolve_media_path /library1/Films/Fixture/f.mkv)" = /tmp/media/Films/Fixture/f.mkv ] \
  || fail "suffix search did not find the queued file"
[ "$(PATH_MAP=/library1:/tmp/media resolve_media_path /library1/Films/Fixture/f.mkv)" = /tmp/media/Films/Fixture/f.mkv ] \
  || fail "PATH_MAP was not applied"
if (PATH_MAP_AUTO=false resolve_media_path /library1/Films/Fixture/f.mkv >/dev/null); then
  fail "PATH_MAP_AUTO=false still resolved the path"
fi
if resolve_media_path /library1/Films/Nope/nope.mkv >/dev/null; then
  fail "resolved a path that matches nothing"
fi
rm -rf /tmp/media/Films
pass "PATH_MAP and suffix search"

echo "== a mounted scratch disk is picked up without SCRATCH_DIR =="
# The image never creates /scratch, so its presence is a bind mount and nothing
# else. Assert that first, or the whole detection is meaningless.
if [ -d /scratch ]; then fail "the image ships a /scratch, detection cannot work"; fi
scratch_of() { ( unset SCRATCH_DIR; DEFAULT_SCRATCH_DIR="$1" . /opt/dovisionarr/lib.sh
                 echo "${SCRATCH_DIR:-<unset>} $_SCRATCH_AUTO" ); }
[ "$(scratch_of /tmp/no-such-scratch)" = "<unset> false" ] || fail "invented a scratch dir that is not mounted"
mkdir -p /tmp/fake-scratch
[ "$(scratch_of /tmp/fake-scratch)" = "/tmp/fake-scratch true" ] || fail "did not detect the mounted scratch dir"
[ "$( ( SCRATCH_DIR=/tmp/explicit; DEFAULT_SCRATCH_DIR=/tmp/fake-scratch . /opt/dovisionarr/lib.sh
        echo "${SCRATCH_DIR} $_SCRATCH_AUTO" ) )" = "/tmp/explicit false" ] || fail "detection overrode an explicit SCRATCH_DIR"
rmdir /tmp/fake-scratch
pass "detected when mounted, absent otherwise, never over an explicit setting"

echo "== scan and report =="
dovisionarr report /tmp/media
dovisionarr scan /tmp/media
pass "scan completed"

echo
echo "all smoke tests passed"
INNER
