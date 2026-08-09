# syntax=docker/dockerfile:1

ARG DOVI_TOOL_VERSION=2.3.3
ARG FFMPEG_VERSION=7.1.5

# --------------------------------------------------------------------------- #
# dovi_tool is published as a static musl binary, one per architecture.
# --------------------------------------------------------------------------- #
FROM debian:trixie-slim AS dovi
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DOVI_TOOL_VERSION
ARG TARGETARCH=""
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x86_64  ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/dovi.tgz \
      "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_TOOL_VERSION}/dovi_tool-${DOVI_TOOL_VERSION}-${arch}-unknown-linux-musl.tar.gz"; \
    tar -xzf /tmp/dovi.tgz -C /tmp; \
    install -m0755 "$(find /tmp -maxdepth 2 -type f -name dovi_tool | head -n1)" /usr/local/bin/dovi_tool; \
    /usr/local/bin/dovi_tool --version

# --------------------------------------------------------------------------- #
# Debian's ffmpeg package is the single largest thing in this image: its
# dependency closure drags in the NVIDIA encode stubs, x264/x265, the AV1
# encoders, Bluray/DVD readers, SDL2 and a network stack. This pipeline uses
# ffmpeg for exactly one job — lift the HEVC track out of a Matroska container
# as Annex-B — and ffprobe to read stream metadata. Neither ever encodes,
# filters or reaches the network, so build the two binaries with everything
# else switched off.
#
# The hevc decoder is the one component enabled beyond strict demux needs:
# avformat_find_stream_info() leans on it to settle r_frame_rate/avg_frame_rate,
# and convert.sh derives mkvmerge's --default-duration from those. Without it
# every file would fall through to the variable-frame-rate warning path.
# --------------------------------------------------------------------------- #
FROM debian:trixie-slim AS ffbuild
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG FFMPEG_VERSION
WORKDIR /src
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl nasm pkg-config xz-utils zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*; \
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
    /ffout/bin/ffprobe -version | head -1; \
    du -h /ffout/bin/ffmpeg /ffout/bin/ffprobe

# --------------------------------------------------------------------------- #
FROM debian:trixie-slim AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DOVI_TOOL_VERSION
ARG VERSION=dev

LABEL org.opencontainers.image.title="dovisionarr" \
      org.opencontainers.image.description="Converts Dolby Vision Profile 7 MKVs to single-layer Profile 8.1 in place, without re-encoding" \
      org.opencontainers.image.source="https://github.com/drumslayers/dovisionarr" \
      org.opencontainers.image.licenses="PolyForm-Noncommercial-1.0.0"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mkvtoolnix jq gosu tini tzdata util-linux ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1000 dovisionarr; \
    useradd  -u 1000 -g 1000 -d /opt/dovisionarr -s /usr/sbin/nologin dovisionarr; \
    mkdir -p /queue/failed /state /media; \
    chown -R dovisionarr:dovisionarr /queue /state

COPY --from=dovi   /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY --from=ffbuild /ffout/bin/ffmpeg       /usr/local/bin/ffmpeg
COPY --from=ffbuild /ffout/bin/ffprobe      /usr/local/bin/ffprobe
COPY scripts/ /opt/dovisionarr/
COPY enqueue.sh /opt/dovisionarr/enqueue.sh

RUN set -eux; \
    chmod +x /opt/dovisionarr/dovisionarr /opt/dovisionarr/entrypoint.sh /opt/dovisionarr/enqueue.sh; \
    ln -sf /opt/dovisionarr/dovisionarr /usr/local/bin/dovisionarr; \
    ffprobe -version | head -1; mkvmerge --version; dovi_tool --version; \
    ffmpeg -hide_banner -demuxers | grep -qw matroska; \
    ffmpeg -hide_banner -muxers   | grep -qw hevc; \
    ffmpeg -hide_banner -bsfs     | grep -qw hevc_mp4toannexb

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

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/dovisionarr/entrypoint.sh"]
CMD ["worker"]

# --------------------------------------------------------------------------- #
# Test-only. The smoke test synthesises its fixtures — x265 encode, flac
# encode, lavfi sources — which the shipped ffmpeg deliberately cannot do.
# Debian's full build lands at /usr/bin/ffmpeg for fixture work only; the
# pipeline still resolves ffmpeg and ffprobe from /usr/local/bin, earlier on
# PATH, so the test exercises the binaries that actually ship.
#
# Build with --target test. Never pushed.
# --------------------------------------------------------------------------- #
FROM base AS test
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ffmpeg; \
    rm -rf /var/lib/apt/lists/*; \
    [ "$(command -v ffmpeg)" = /usr/local/bin/ffmpeg ]

# --------------------------------------------------------------------------- #
# Default target: the shipped image, with none of the test tooling above.
# --------------------------------------------------------------------------- #
FROM base AS runtime
