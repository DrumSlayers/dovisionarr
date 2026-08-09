# syntax=docker/dockerfile:1

ARG DOVI_TOOL_VERSION=2.3.3

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
FROM debian:trixie-slim
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
        ffmpeg mkvtoolnix jq gosu tini tzdata util-linux ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1000 dovisionarr; \
    useradd  -u 1000 -g 1000 -d /opt/dovisionarr -s /usr/sbin/nologin dovisionarr; \
    mkdir -p /queue/failed /state /media; \
    chown -R dovisionarr:dovisionarr /queue /state

COPY --from=dovi /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY scripts/ /opt/dovisionarr/
COPY enqueue.sh /opt/dovisionarr/enqueue.sh

RUN set -eux; \
    chmod +x /opt/dovisionarr/dovisionarr /opt/dovisionarr/entrypoint.sh /opt/dovisionarr/enqueue.sh; \
    ln -sf /opt/dovisionarr/dovisionarr /usr/local/bin/dovisionarr; \
    ffprobe -version | head -1; mkvmerge --version; dovi_tool --version

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
