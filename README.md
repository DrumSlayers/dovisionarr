# dovisionarr

**Automatic Dolby Vision Profile 7 → Profile 8.1 conversion for Jellyfin, Plex, Emby, Sonarr and
Radarr libraries — no re-encode.** Fixes washed-out Dolby Vision playback and Direct Play/Sound failures
on Android TV, Philips / LG / Samsung / Sony TVs, Shield and Fire TV.

[![ci](https://github.com/drumslayers/dovisionarr/actions/workflows/ci.yml/badge.svg)](https://github.com/drumslayers/dovisionarr/actions/workflows/ci.yml)
[![ghcr](https://img.shields.io/badge/ghcr.io-dovisionarr-blue)](https://github.com/drumslayers/dovisionarr/pkgs/container/dovisionarr)
[![license](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-green)](LICENSE)

Converts Dolby Vision **Profile 7** MKVs to single-layer **Profile 8.1**, in place, without
re-encoding a single frame. Point it at your library, wire it into Sonarr and Radarr, forget it.

Profile 7 is the dual-layer format used on UHD Blu-ray. It is a disc format, and a lot of
streaming clients — Jellyfin on Android TV and most built-in TV players among them (hello ExoPlayer) cannot
handle it properly. You get a washed-out picture, or the file drops out of Direct Play and your lossless
audio gets transcoded to stereo. Profile 8.1 carries the almost-same dynamic metadata in a single layer
that plays essentially everywhere.

The video bitstream is copied, not re-encoded. Every audio track, subtitle, chapter and
attachment survives. A 60 GB remux takes a few minutes, not a few hours.

---

## How it fits together

```
   ┌───────────┐   "I just imported a file"   ┌──────────────────────────────┐
   │  Radarr   │ ───────────────────────────► │  enqueue.sh                  │
   │  Sonarr   │      (Custom Script)         │  writes /queue/<id>.job      │
   └───────────┘                              └──────────────┬───────────────┘
                                                             │
                       ┌─────────────────────────────────────▼─────────────────┐
                       │  dovisionarr worker                                   │
                       │  · drains the queue                                   │
                       │  · sweeps the library inside a maintenance window     │
                       └─────────────────────────────────────┬─────────────────┘
                                                             │
                                              ffprobe: what Dolby Vision profile?
                                                             │
                            ┌────────────────────────────────┴──────────────┐
                            │                                               │
                   profile ≠ 7 (or none)                             profile = 7
                            │                                               │
                    never opened for writing                      convert, verify,
                    hard links untouched                          rename over the original
```

---

## Why this exists

Struggled a long time with my **Philips 55OLED708** and [Jellyfin's issue with HDR10 fallback on DV Profile 7](https://github.com/jellyfin/jellyfin-androidtv/issues/5073), and I had to deal with two choices that are both unacceptable: 
- When forcing the player (Wholphin here) to bypass DV 7 compatibility checks, the movie was **washed out** (grey, flat, low contrast, obviously wrong) but sound was truely bypassed to my home theater system.
- When letting the player do its job, the picture was correct, but the sound was in pure stereo. I think because it bypassed ExoPlayer's capabilities and the audio was not bypassed to the home theater system anymore. (The TV was in fact not even receiving HDR10+ or Dolby Vision, but only SDR)

The cause is not the TV, not Jellyfin, and not a setting. Philips' built-in player and the
Jellyfin Android TV app both run on **ExoPlayer / Media3**, which does not consume a dual-layer
Profile 7 enhancement layer. Same story on LG webOS, Samsung Tizen, Sony, Shield, Fire TV and
Chromecast: Profile 7 is a *disc* format, and these are not disc players.

Converting the library to Profile 8.1 removed both symptoms at once — correct HDR picture,
Direct Play restored, lossless audio intact. Doing that by hand across 80+ TB was not going to
happen, so it became some claude prompts and a container that watches Sonarr and Radarr and does it on import. That is
dovisionarr.

If the paragraph above describes your setup, this repo is for you.

### Does this fix your problem?

| Symptom | dovisionarr helps? |
|---|---|
| Dolby Vision remux looks **washed out / grey / flat / faded** on the TV | **Yes** — this is the Profile 7 failure, gone after conversion |
| **Pink, green or purple tint**, or blown-out highlights on a DV file | **Yes** — same root cause, dual-layer stream fed to a single-layer decoder |
| Jellyfin / Plex / Emby **transcodes video** on a file that should Direct Play | **Yes** — removes the DV-profile-triggered transcode |
| **TrueHD / DTS-HD MA downmixed to stereo** because the file left Direct Play | **Mostly** — fixes the video-triggered case; the client can still downmix on its own ([details](#troubleshooting)) |
| File plays as **HDR10 but Dolby Vision never engages** | **Yes** — 8.1 signals DV in a way ExoPlayer clients accept |
| `dv_profile=7`, `bl_signal_compatibility_id=6`, `MEL` / `FEL` in MediaInfo | **Yes** — exactly the input case |
| DV **Profile 5** file looks purple/green | **No** — different problem, P5 has no HDR10 base layer |
| **HDR10+** metadata, no Dolby Vision | **No** — nothing to convert |
| SDR file, or DV that already Direct Plays fine | **No** — dovisionarr skips it, never opens it for writing |

Affected clients seen in the wild: Jellyfin Android TV, Plex and Emby on the same TVs, Philips
OLED (`55OLED708`, `OLED8xx`, `OLED9xx`), LG webOS, Samsung Tizen, Sony Bravia, Nvidia Shield,
Fire TV, Chromecast with Google TV, Apple TV via Infuse in some paths.

---

## Quick start

The following assumes:
- you already have Sonarr and Radarr running in Docker, 
- your media is mounted at `/mnt/library1` in both containers. Adjust the paths to match your setup.
- dovisionarr is running on the same host as the *arr stack, and can see the same media path.
- dovisionarr docker's folder is /srv/dovisionarr, and you have write access to it. (You can change the path, but adjust the paths below accordingly.)

### 1. Run the container

```yaml
services:
  dovisionarr:
    image: ghcr.io/drumslayers/dovisionarr:latest
    container_name: dovisionarr
    restart: unless-stopped
    environment:
      PUID: 1000                 # same UID/GID as Sonarr, Radarr and your media
      PGID: 1000
      TZ: Europe/Paris
      SCAN_ENABLED: "true"       # nightly sweep of the whole library
      SCAN_WINDOW: "02:00-06:00"
    volumes:
      - /mnt/library1:/media     # SAME path as in Sonarr/Radarr, see below
      - /srv/dovisionarr/queue:/queue
      - /srv/dovisionarr/state:/state
```

```sh
docker compose up -d
docker logs -f dovisionarr
```

> **The media path should match.** Radarr hands over the path *it* sees. If Radarr has
> `/mnt/library1:/library1`, then the simplest setup is `/mnt/library1:/library1` on dovisionarr
> too — same string, both sides — with `SCAN_PATHS: "/library1"`.
>
> If you cannot or do not want to change the mount, map the paths instead:
>
> ```yaml
>       PATH_MAP: "/library1:/media"   # what the *arrs see : what dovisionarr sees
> ```
>
> With neither of those, dovisionarr still tries to find the queued file under `SCAN_PATHS`
> by matching the tail of the path, and logs the translation it used. Set `PATH_MAP_AUTO: "false"`
> to turn that off and drop unresolvable jobs instead.

### 2. Wire up Sonarr and Radarr

Add one volume to each *arr — the shared queue directory:
PS: Point out to your dovisionarr container path in the volumes if you are using a different path than `/srv/dovisionarr` in the example below.

```yaml
    volumes:
      - /srv/dovisionarr/queue:/queue
```

Recreate the container (`docker compose up -d`), then in the web UI:

**Settings → Connect → `+` → Custom Script**

| Field | Value |
|---|---|
| Name | `dovisionarr` |
| Path | `/queue/enqueue.sh` |
| Triggers | ☑ On Import  ☑ On Upgrade |

Hit **Test** — it should say `dovisionarr: queue /queue is writable — hook OK`. Save.

That is the whole integration. Every imported or upgraded file gets queued; dovisionarr ignores
everything that is not Profile 7.

### 3. Deal with what is already on disk

See what a sweep would touch, without changing anything:

```sh
docker exec dovisionarr dovisionarr report
```

Then convert the backlog. It is safe to interrupt and safe to re-run:

```sh
docker exec dovisionarr dovisionarr scan
```

On a large library, leave `SCAN_ENABLED=true` and let the nightly window chew through it a few
titles at a time instead.

---

## Configuration

Everything is environment variables. All of them are optional.

| Variable | Default | What it does |
|---|---|---|
| `PUID` / `PGID` | `1000` | User the worker runs as. Match your *arr stack. |
| `TZ` | `UTC` | Timezone, used by the scan window. |
| `SCAN_ENABLED` | `false` | Turn the scheduled library sweep on. |
| `SCAN_WINDOW` | `02:00-06:00` | Maintenance window. Wrapping past midnight (`22:00-04:00`) works. |
| `SCAN_DAYS` | `*` | `*`, or a list like `sun` / `sat,sun`. |
| `SCAN_PATHS` | `/media` | Colon-separated roots to sweep. |
| `SCAN_EXCLUDE` | `downloads,remote_sync,incomplete,.recycle` | Directory names never entered. |
| `SCAN_STOP_AT_WINDOW_END` | `true` | Stop cleanly when the window closes, resume next night. |
| `SCAN_CACHE` | `true` | Remember which files are not P7, so re-scans are fast. |
| `SCAN_PROGRESS_EVERY` | `200` | Log a progress line every N files scanned. `0` turns it off. |
| `PATH_MAP` | unset | Translate the paths Sonarr/Radarr queue. `"/library1:/media"`, comma-separated for several. |
| `PATH_MAP_AUTO` | `true` | When a queued path does not resolve, look for the same file under `SCAN_PATHS`. |
| `SCRATCH_DIR` | `/scratch` when mounted, else next to the media | Where the temporary base layer goes. Bind-mounting a disk at `/scratch` is enough — you do not have to set this. See [disk I/O](documentation/how-it-works.md#one-temporary-file-and-why). |
| `DRY_RUN` | `false` | Probe and report, never write. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |
| `LOG_COLOR` | `auto` | `always`, `never`. `NO_COLOR=1` also works. |
| `POLL_INTERVAL` | `15` | Seconds between queue checks. |
| `NICE` / `IONICE_CLASS` / `IONICE_LEVEL` | `10` / `2` / `7` | Keeps the box responsive during a conversion. |
| `PRESERVE_MTIME` | `true` | Keep the original modification time. |

### The scheduled scan

The worker checks the clock every poll; when the window opens it starts sweeping, and when the window closes it finishes the file
it is on and stops. It runs at most once per window.

```
 00:00        02:00                                06:00            24:00
   │            ├───────────── scanning ─────────────┤                │
   │            ▲                                    ▲                │
   │      window opens,                    window closes, current file
   │      scan starts                      finishes, then it stops
```

A season pack that imports at 03:15 still gets converted immediately through the queue — the
scan is the safety net for manual imports, downtime and anything the hook missed.

---

## Commands

```sh
docker exec dovisionarr dovisionarr report          # list Profile 7 files, change nothing
docker exec dovisionarr dovisionarr scan /media/Films
docker exec dovisionarr dovisionarr convert "/media/Films/Avatar (2009)/Avatar (2009).mkv"
docker exec dovisionarr dovisionarr probe  "/media/Films/Avatar (2009)/Avatar (2009).mkv"
```

`probe` is the quickest way to answer "does this file actually need anything?":

```
/media/Films/Avatar (2009)/Avatar (2009) Remux-2160p.mkv
  codec      hevc
  duration   2h42m8s
  tracks     7 audio, 4 subtitle
  dv profile 7  ·  el=1  ·  rpu=1  ·  bl_compat=6
  verdict    needs conversion
```

---

## How it deeply works

see [how-it-works.md](documentation/how-it-works.md) for a detailed explanation of the conversion process, the
Dolby Vision bitstream, and why the pipeline is shaped the way it is.

Skip this if you just want it running. Read it if you want to know exactly what is being done
to your files.

---

## Troubleshooting

**The hook test fails in Sonarr/Radarr.** The queue directory is not mounted or not writable
from inside the *arr container. Both containers need the same queue path, and the same PUID/PGID.

**Jobs are queued but nothing happens.** The path Radarr wrote does not exist inside dovisionarr.
Check `docker logs dovisionarr` for `queued file is gone`, then make the media mount path
identical in both compose files.

**Still getting stereo audio after conversion.** That half is a separate, client-side problem —
see [jellyfin-androidtv#5303](https://github.com/jellyfin/jellyfin-androidtv/issues/5303) and
[#5517](https://github.com/jellyfin/jellyfin-androidtv/issues/5517). Converting to 8.1 removes
the *video*-triggered transcode, which fixes it in a lot of cases, but the app can still downmix
on its own. In order: pick the DD/DD+ 5.1 track that most remuxes already carry, enable audio
passthrough in the client and eARC on the TV, or use Kodi / an mpv-based player instead.

**A conversion failed.** The job moves to `/queue/failed`. Your original was not touched. Move
the `.job` file back into `/queue` to retry it.

**Free space errors.** Preflight wants ~0.9× the source size on the scratch filesystem and
~1.1× next to the media. Use `SCRATCH_DIR` to spread that across two disks.

---

## Credits

Built on [dovi_tool](https://github.com/quietvoid/dovi_tool) by quietvoid, which does all of the
actual Dolby Vision work, plus [MKVToolNix](https://mkvtoolnix.download/) and
[FFmpeg](https://ffmpeg.org/). dovisionarr is the boring glue around them.

Almost all of this repository — the scripts, the Dockerfile, the CI, and a bit of this README — was written
by Claude (Anthropic), including the pipe-versus-file testing that decided the pipeline shape.
It has been tested end to end on a 80+ TB library, against real Profile 7 remuxes. Read the code before you point it
at 80 TB of media anyway.

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE) — free to use, modify and
redistribute for any noncommercial purpose, as long as you keep the copyright notice.

The container bundles third-party tools under their own licenses: mkvtoolnix (GPL), ffmpeg
(LGPL-2.1+ — built from source with no GPL components, see below), dovi_tool (MIT), jq (MIT),
tini (MIT), gosu (Apache-2.0). dovisionarr only invokes them as separate processes, so their
terms apply to those binaries, not to this project's scripts.

ffmpeg is not the distribution package. It is compiled in the `ffbuild` stage of the
[Dockerfile](Dockerfile) with `--disable-everything`, then re-enabled down to what the pipeline
touches: the Matroska demuxer, the HEVC parser, decoder and muxer, the `hevc_mp4toannexb`
bitstream filter, and the file and pipe protocols. No encoders, no filters, no network, no
`libavdevice`. The distribution build would otherwise pull in the NVIDIA encode stubs, x264,
x265, the AV1 encoders, Bluray and DVD readers and SDL2 — several hundred megabytes of
dependency closure for a container that only ever runs `-c:v copy`. Bump `FFMPEG_VERSION` in the
Dockerfile to pick up upstream fixes; unlike the apt packages it is pinned and does not move on
the weekly rebuild.

---

## Keywords

Here so search engines and the next person with a washed-out remux can actually find this.

**Problem phrases** — dolby vision washed out · dolby vision grey washed out picture jellyfin ·
profile 7 washed out android tv · dolby vision looks faded on tv · dv profile 7 not playing
correctly · dolby vision pink green tint · dolby vision low contrast flat image · remux washed
out but plays fine on pc · jellyfin transcoding dolby vision remux · jellyfin truehd downmixed to
stereo · dts-hd ma stereo only android tv · direct play fails dolby vision · philips oled dolby
vision washed out · philips 55OLED708 dolby vision problem · lg webos profile 7 · samsung tizen
dolby vision mkv · nvidia shield dolby vision profile 7 · exoplayer dual layer dolby vision ·
media3 dolby vision enhancement layer

**Solution / tooling** — convert dolby vision profile 7 to profile 8.1 · dv p7 to p8.1 · dolby
vision profile 8.1 conversion without re-encoding · dovi_tool convert -m 2 · dovi_tool discard
enhancement layer · mkvmerge dolby vision remux · strip dolby vision enhancement layer · FEL to
MEL · single layer dolby vision mkv · bl_signal_compatibility_id 1 · RPU NAL 62 · lossless
dolby vision remux · batch convert dolby vision library · automate dolby vision conversion ·
sonarr custom script post processing · radarr custom script on import · jellyfin direct play fix
· self-hosted media server dolby vision automation

**Topics** — `dolby-vision` `dolby-vision-profile-7` `dolby-vision-profile-8` `dovi-tool` `dovi`
`hdr` `hdr10` `hevc` `mkv` `mkvtoolnix` `ffmpeg` `remux` `uhd-bluray` `transcoding` `no-reencode`
`jellyfin` `plex` `emby` `sonarr` `radarr` `arr-stack` `servarr` `docker` `homelab` `self-hosted`
`media-server` `automation` `exoplayer` `android-tv` `philips-oled` `webos` `tizen`
