
# How it deeply works
### What Profile 7 actually is

A Dolby Vision Profile 7 UHD Blu-ray remux is a single HEVC track that carries three things
interleaved at the NAL unit level:

```
Profile 7, dual layer, single track          →   Profile 8.1, single layer
┌──────────────────────────────────────┐         ┌──────────────────────────────────────┐
│ NAL 32/33/34   VPS / SPS / PPS       │  kept   │ NAL 32/33/34   VPS / SPS / PPS       │
│ NAL 35         access unit delimiter │  kept   │ NAL 35         access unit delimiter │
│ NAL 39         SEI (HDR10 metadata)  │  kept   │ NAL 39         SEI (HDR10 metadata)  │
│ NAL 0-21       base layer slices     │ ═════►  │ NAL 0-21       base layer slices     │
│                (HDR10, 10-bit, PQ)   │ verbatim│                (byte for byte equal) │
│ NAL 62         RPU, profile 7        │ rewrite │ NAL 62         RPU, profile 8.1      │
│ NAL 63         enhancement layer     │ dropped │                                      │
└──────────────────────────────────────┘         └──────────────────────────────────────┘
    bl_signal_compatibility_id = 6                   bl_signal_compatibility_id = 1
```

- **Base layer (BL)** — an ordinary HEVC Main10 stream, BT.2020 primaries, PQ transfer. On its
  own it is a perfectly correct HDR10 picture. This is what every non-DV player already shows.
- **RPU** (NAL 62) — per-frame Dolby Vision metadata: the L1 dynamic range stats, the L2/L8
  trims, and on FEL discs the luma/chroma mapping coefficients that describe how to combine the
  layers.
- **EL** (NAL 63) — the enhancement layer, a second encoded video stream wrapped in
  unspecified-type NALs so it can ride in the same track. **MEL** carries essentially nothing;
  **FEL** carries real residual detail toward the ~12-bit master.

Measured on a real 20 seconds slice of a P7 FEL remux (483 frames):

| NAL type | what | units | bytes before | bytes after |
|---|---|---|---|---|
| 1, 20 | base layer slices | 483 | 20.35 MB | **20.35 MB, identical SHA-256** |
| 62 | RPU | 483 | 0.11 MB | 0.09 MB (rewritten) |
| 63 | enhancement layer | 1616 | 1.60 MB | — (dropped) |
| 32-35, 39 | parameter sets, AUD, SEI | 1196 | unchanged | unchanged |

### Why players break on it

Profile 7 was designed for disc players. ExoPlayer / Media3 — which is what Jellyfin's Android
TV app and most TV built-in players use — does not consume the dual-layer EL. Two failure modes:

- The player flags the stream as Dolby Vision, feeds the panel the base layer without applying
  the RPU correctly, and you get the washed-out, low-contrast picture.
- Or the file fails Direct Play, the server falls back to an HLS remux, and in that path
  Jellyfin transcodes TrueHD / DTS-HD MA down to stereo AAC.

Profile 8.1 sets `bl_signal_compatibility_id = 1`, which says "the base layer is valid HDR10,
apply the RPU on top if you can". Clients that understand DV use the metadata; clients that
do not fall back to correct HDR10. Either way it Direct Plays.

### What it costs you

`dovi_tool -m 2` keeps the per-frame RPU trims (L1, L2, L8) and removes the FEL luma/chroma
mapping, because leaving a mapping in place while discarding the layer it describes would be
wrong. So:

- **MEL sources**: nothing is lost. The EL was carrying nothing.
- **FEL sources**: you lose the residual bit-depth refinement. In practice that means slightly
  more banding in smooth gradients — skies, slow fades, spotlight falloff — and a touch less
  shadow nuance. It is **not** an exposure change, not crushed blacks, not blown highlights, and
  not the washout you are trying to fix. The dynamic trims are preserved.

If you keep your originals seeding, the FEL never actually leaves your disk. Point a FEL-capable
player (Zidoo, Dune, madVR) at the original if you ever want it — those are the only things that
can display it anyway.

Check which one you have: `dovi_tool info -s -i rpu.bin` after `dovi_tool extract-rpu`.

### The pipeline

```
 source.mkv  (P7, dual layer)
     │
     │  ffmpeg -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc -
     ▼
  HEVC elementary stream ──── pipe, never touches disk ────┐
                                                           ▼
                                        dovi_tool -m 2 convert --discard
                                                           │
                                                           ▼
                                           base layer + rewritten RPU
                                              (one temporary file)
                                                           │
  source.mkv ── audio, subs, chapters, attachments ──►  mkvmerge -D
                                                           │
                                                           ▼
                                             .dovisionarr-out-XXXXXX.mkv
                                                           │
                                                     verify, then
                                                     rename() over source.mkv
```

Then four gates before anything is replaced. If any of them fails, the temporary file is
deleted and the original is left exactly as it was:

1. the output probes as DV profile 8,
2. `bl_signal_compatibility_id` is 1,
3. audio and subtitle track counts match the source,
4. duration has not drifted by more than 2 seconds.

The final `mv` is a same-filesystem `rename(2)`. It is atomic: a reader either gets the old
file or the new one, never a half-written mix. Ownership, permissions and mtime are copied from
the original first.

The frame rate is passed to mkvmerge explicitly (`--default-duration 0:24000/1001fps`, read from
the source). A raw elementary stream carries no container timing; mkvmerge normally reads it
from the SPS VUI, but a stream without VUI timing would silently land on mkvmerge's 25 fps
default and desync every audio track. Variable frame rate sources are detected and left to
mkvmerge's own logic, with a warning.

### One temporary file, and why

The obvious thing to do is pipe `dovi_tool` straight into `mkvmerge` and write nothing in
between. That does not work, and it is worth being precise about why, because it is the one
place where this design is not what it "should" be.

**mkvmerge cannot read from a pipe.** It seeks in its inputs while probing. Tested on both
v74 and v92, with a FIFO, with `/dev/stdin`, and with process substitution:

```
terminate called after throwing an instance of 'mtx::mm_io::seek_x'
  what():  seek in file error
```

**ffmpeg cannot replace it.** Two independent blockers, both verified on ffmpeg 8.1:

- Muxing a raw HEVC elementary stream into Matroska fails outright —
  `Can't write packet with unknown timestamp`. The raw demuxer produces no timestamps, and
  forcing them in decode order would scramble presentation order on any B-frame content, which
  is all of it.
- Even where it does mux (MP4), ffmpeg writes **no Dolby Vision configuration record** from an
  elementary stream — `side_data_list` comes back `null`. The container-level DV signalling is
  exactly what Jellyfin reads to decide Direct Play, so losing it defeats the purpose.

`ffmpeg -bsf:v dovi_rpu` only strips or compresses metadata; it cannot do the Profile 7 → 8.1
conversion. dovi_tool is required, and mkvmerge is required, and mkvmerge needs a real file.

So one temporary file it is — the base layer, roughly 90 % of the source's video track. What
dovisionarr does instead is let you put it somewhere that does not hurt. With `SCRATCH_DIR`
pointing at an SSD, the media array only ever does one sequential read and one sequential write:

| | media disk | scratch disk |
|---|---|---|
| `SCRATCH_DIR` unset (default) | read 2×, write 2× | — |
| `SCRATCH_DIR=/scratch` on another disk | **read 1×, write 1×** | read 1×, write 1× |

```yaml
    environment:
      SCRATCH_DIR: /scratch
    volumes:
      - /mnt/nvme/dovisionarr:/scratch
```

The extraction step itself is already piped — the dual-layer stream is read once and never
written anywhere.

### Hard links and seeding

This matters if you seed what you download.

A file that is not Profile 7 is probed and then closed. It is never opened for writing, never
renamed, never touched. Hard links between your download directory and your library survive
untouched, which is the whole point of hard links.

A file that *is* Profile 7 gets replaced, and the rename breaks that title's hard link. After
the conversion:

- the original Profile 7 file still exists in your download directory, byte-identical, still
  seeding, still counting for ratio;
- the Profile 8.1 file exists only in the library folder;
- Sonarr and Radarr keep tracking the same path. DV profile is not a quality attribute they
  track, so `Remux-2160p` stays `Remux-2160p`: no re-grab, no duplicate. Rescan only if you want
  the UI to show the new size.

The Profile 8.1 file cannot seed the original torrent — different bytes, different hash. Keeping
the original is how you keep seeding.

Space, per converted title: about 1.8× while both exist, dropping to about 0.9× once you stop
seeding the original. Directories named `downloads`, `remote_sync`, `incomplete` and `.recycle`
are never entered by a scan, so an active download is never rewritten mid-flight.
