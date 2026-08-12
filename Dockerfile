# syntax=docker/dockerfile:1

ARG DOVI_TOOL_VERSION=2.3.3
ARG FFMPEG_VERSION=7.1.5

# --------------------------------------------------------------------------- #
# The image is Alpine, not Debian, and the reason is mkvtoolnix. Both
# distributions link it against Qt6Core — that is not optional, mkvtoolnix's
# own configure refuses to build without Qt even with --disable-gui — and
# Qt6Core pulls in ICU. Debian's libicu ships the full 30 MB icudata blob;
# Alpine ships icu-data-en at 2.9 MB. That single difference, plus a
# mkvtoolnix package a quarter the size and su-exec in place of gosu, is worth
# about 150 MB of image.
#
# dovi_tool is published as a static musl binary, one per architecture, so it
# was always the right fit here; ffmpeg is built from source against musl in
# the ffbuild stage below.
# --------------------------------------------------------------------------- #
FROM alpine:3.22 AS dovi
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG DOVI_TOOL_VERSION
ARG TARGETARCH=""
RUN set -eux; \
    apk add --no-cache ca-certificates curl tar; \
    case "${TARGETARCH:-$(apk --print-arch)}" in \
      amd64|x86_64)  arch=x86_64  ;; \
      arm64|aarch64) arch=aarch64 ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/dovi.tgz \
      "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_TOOL_VERSION}/dovi_tool-${DOVI_TOOL_VERSION}-${arch}-unknown-linux-musl.tar.gz"; \
    tar -xzf /tmp/dovi.tgz -C /tmp; \
    install -m0755 "$(find /tmp -maxdepth 2 -type f -name dovi_tool | head -n1)" /usr/local/bin/dovi_tool; \
    /usr/local/bin/dovi_tool --version

# --------------------------------------------------------------------------- #
# The distribution ffmpeg package is the single largest thing this image could
# carry: its dependency closure drags in the NVIDIA encode stubs, x264/x265,
# the AV1 encoders, Bluray/DVD readers, SDL2 and a network stack. This pipeline
# uses ffmpeg for exactly one job — lift the HEVC track out of a Matroska
# container as Annex-B — and ffprobe to read stream metadata. Neither ever
# encodes, filters or reaches the network, so build the two binaries with
# everything else switched off.
#
# The hevc decoder is the one component enabled beyond strict demux needs:
# avformat_find_stream_info() leans on it to settle r_frame_rate/avg_frame_rate,
# and convert.sh derives mkvmerge's --default-duration from those. Without it
# every file would fall through to the variable-frame-rate warning path.
#
# Everything installed here stays in this stage: the runtime image below only
# takes the two finished binaries across a COPY --from, so the toolchain is
# never part of a shipped layer.
# --------------------------------------------------------------------------- #
FROM alpine:3.22 AS ffbuild
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG FFMPEG_VERSION
WORKDIR /src
RUN set -eux; \
    apk add --no-cache build-base ca-certificates curl nasm pkgconf tar zlib-dev; \
    curl -fsSL --retry 3 --retry-delay 2 \
      "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
      | tar -xz -C /src --strip-components=1; \
    [ "$(cat RELEASE)" = "${FFMPEG_VERSION}" ]; \
    ./configure \
      --prefix=/ffout \
      --disable-autodetect \
      --disable-everything \
      --disable-doc \
      --disable-debug \
      --disable-network \
      --disable-avdevice \
      --disable-postproc \
      --disable-ffplay \
      --enable-small \
      --enable-zlib \
      --enable-demuxer=matroska,hevc \
      --enable-muxer=hevc \
      --enable-parser=hevc \
      --enable-decoder=hevc \
      --enable-bsf=hevc_mp4toannexb,extract_extradata,null \
      --enable-filter=null,anull \
      --enable-protocol=file,pipe; \
    make -j"$(nproc)"; \
    make install; \
    strip /ffout/bin/ffmpeg /ffout/bin/ffprobe; \
    /ffout/bin/ffprobe -version | sed -n 1p; \
    du -h /ffout/bin/ffmpeg /ffout/bin/ffprobe

# --------------------------------------------------------------------------- #
FROM alpine:3.22 AS base
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG DOVI_TOOL_VERSION
ARG VERSION=dev

LABEL org.opencontainers.image.title="dovisionarr" \
      org.opencontainers.image.description="Converts Dolby Vision Profile 7 MKVs to single-layer Profile 8.1 in place, without re-encoding" \
      org.opencontainers.image.source="https://github.com/drumslayers/dovisionarr" \
      org.opencontainers.image.licenses="PolyForm-Noncommercial-1.0.0"

# Three of these are here to fill gaps BusyBox leaves, not out of habit:
#   bash       the scripts use arrays and ${var,,}
#   coreutils  BusyBox has no numfmt, and its date cannot parse -d yesterday
#   shadow     BusyBox has no usermod/groupmod, which entrypoint.sh needs to
#              remap the account onto PUID/PGID
# No ca-certificates: nothing in the runtime ever opens a socket. flock and
# ionice come from BusyBox and are used through the fd and command forms only,
# which it implements.
#
# mkvtoolnix ships four binaries and the pipeline only ever calls mkvmerge, so
# the other three go straight back out along with the docs.
RUN set -eux; \
    apk add --no-cache bash coreutils jq mkvtoolnix shadow su-exec tini tzdata; \
    rm -rf /usr/bin/mkvextract /usr/bin/mkvinfo /usr/bin/mkvpropedit \
           /usr/share/doc /usr/share/man /usr/share/locale; \
    addgroup -g 1000 dovisionarr; \
    adduser -u 1000 -G dovisionarr -h /opt/dovisionarr -s /sbin/nologin -D dovisionarr; \
    mkdir -p /queue/failed /state /media; \
    chown -R dovisionarr:dovisionarr /queue /state

COPY --from=dovi    /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY --from=ffbuild /ffout/bin/ffmpeg        /usr/local/bin/ffmpeg
COPY --from=ffbuild /ffout/bin/ffprobe       /usr/local/bin/ffprobe
COPY scripts/ /opt/dovisionarr/
COPY enqueue.sh /opt/dovisionarr/enqueue.sh

# The checks below read every byte their producer writes — sed -n 1p rather
# than head -1, grep without -q. A reader that exits early closes the pipe, the
# producer takes SIGPIPE, and pipefail turns that into a failed build.
RUN set -eux; \
    chmod +x /opt/dovisionarr/dovisionarr /opt/dovisionarr/entrypoint.sh /opt/dovisionarr/enqueue.sh; \
    ln -sf /opt/dovisionarr/dovisionarr /usr/local/bin/dovisionarr; \
    ffprobe -version | sed -n 1p; mkvmerge --version; dovi_tool --version; \
    ffmpeg -hide_banner -demuxers | grep -w matroska >/dev/null; \
    ffmpeg -hide_banner -muxers   | grep -w hevc >/dev/null; \
    ffmpeg -hide_banner -bsfs     | grep -w hevc_mp4toannexb >/dev/null; \
    numfmt --to=iec --suffix=B --format='%.1f' 1234567 >/dev/null; \
    date -d yesterday +%F >/dev/null; \
    bash -c 'x=ABC; [ "${x,,}" = abc ]'

ENV DOVISIONARR_VERSION="${VERSION}" \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    QUEUE_DIR=/queue \
    STATE_DIR=/state \
    SCAN_PATHS=/media \
    LOG_LEVEL=info \
    LOG_COLOR=auto \
    POLL_INTERVAL=15

# The worker ticks a heartbeat every 30s, including mid-conversion.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
  CMD test $(( $(date +%s) - $(cat "$STATE_DIR/heartbeat") )) -lt 120

# -g: signals go to the whole process group, so a `docker stop` reaches ffmpeg,
# dovi_tool and mkvmerge as well. Without it a conversion keeps running until
# the stop timeout expires and is then SIGKILLed, which strands the temp files
# the shell traps would otherwise have removed.
ENTRYPOINT ["/sbin/tini", "-g", "--", "/opt/dovisionarr/entrypoint.sh"]
CMD ["worker"]

# --------------------------------------------------------------------------- #
# Test-only. The smoke test synthesises its fixtures — x265 encode, flac
# encode, lavfi sources — which the shipped ffmpeg deliberately cannot do.
# Alpine's full build lands at /usr/bin/ffmpeg for fixture work only; the
# pipeline still resolves ffmpeg and ffprobe from /usr/local/bin, earlier on
# PATH, so the test exercises the binaries that actually ship.
#
# Build with --target test. Never pushed.
# --------------------------------------------------------------------------- #
FROM base AS test
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN set -eux; \
    apk add --no-cache ffmpeg; \
    [ "$(command -v ffmpeg)" = /usr/local/bin/ffmpeg ]; \
    /usr/bin/ffmpeg -hide_banner -encoders | grep -w libx265 >/dev/null; \
    /usr/bin/ffmpeg -hide_banner -encoders | grep -w flac >/dev/null

# --------------------------------------------------------------------------- #
# Default target: the shipped image, with none of the test tooling above.
# --------------------------------------------------------------------------- #
FROM base AS runtime
