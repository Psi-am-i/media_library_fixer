# media_library_fixer
(or remux_&_faststart_everything_2_mp4)

- Get your media library working on almost any device, start streaming quickly and lose zero quality!
- Converts MKV, AVI, MPG, WMV, and MP4 files to faststart-compatible MP4 using FFmpeg. Files are remuxed instead of transcoded (the audio and video are put into a new container but otherwise untouched).
- If source files use a codec that cannot be put into an MP4 (mainly old files), then they will be transcoded - but this is the only circumstance.
- Built for media libraries on network drives — all remuxing or transcoding happens locally on the machine running the script, then the output is moved to its destination, keeping network write traffic to a single sequential pass.

## Features

- **Three modes** — remux-only, faststart-only, or both
- **Smart remux** — stream-copies video and audio; falls back to AAC if the audio codec is incompatible with MP4
- **Faststart detection** — inspects the `moov`/`mdat` atom order and skips the faststart pass if it is already correct
- **Video-only support** — audio and subtitle maps use optional (`?`) flags so video-only files are handled without errors
- **Subtitle extraction** — exports text-based subtitle tracks (SRT, ASS, WebVTT, MOV_TEXT) to sidecar `.srt` files alongside the output
- **Legacy format support** — AVI, MPG/MPEG, WMV including VC-1/WMV3 codecs that cannot be stream-copied (re-encoded via libx264)
- **Parallel processing** — configurable job count for concurrent conversions via `xargs -P`
- **Local temp processing** — remux/encode runs in `/tmp/mp4work` before being moved to the destination, keeping the network path free of partial writes
- **Safe from home directory** — `~/Library` and other macOS system folders are excluded from the `find` scan
- **Problem summary** — prints a consolidated list of files that need attention at the end of each run

## Requirements

- [`ffmpeg`](https://ffmpeg.org/download.html) and `ffprobe` in your `PATH` (or set via env vars)
- `python3` (standard library only — used for faststart atom detection)
- macOS or Linux

## Usage

```bash
./everything_2_faststart_mp4.sh [SRC]
```

`SRC` is the directory to scan recursively (default: current directory). The script prompts interactively for all options on startup:

- **Processing mode** — remux only / faststart only / both
- **Output location** — in place, or a separate folder (flat or mirrored structure)
- **Original handling** — archive to a folder, delete, or leave in place
- **Parallel jobs** — 1, 2, or 4

### Graceful stop

```bash
touch /tmp/mp4_stop   # finish current file(s), skip the rest
rm /tmp/mp4_stop      # clear the stop flag to resume/re-run
```

### Environment variables

| Variable | Description |
|----------|-------------|
| `FFMPEG` | Override the `ffmpeg` binary path |
| `FFPROBE` | Override the `ffprobe` binary path |

## Processing modes

| Mode | What it does |
|------|--------------|
| `remux` | Converts MKV / AVI / MPG / WMV → MP4 via stream copy (or re-encode for incompatible codecs). Skips the faststart pass entirely. |
| `faststart` | Applies `-movflags +faststart` to existing MP4s that do not already have it. Skips all non-MP4 formats. |
| `both` | Remuxes first, then applies faststart. Default. |

## Supported input formats

| Extension | Strategy |
|-----------|----------|
| `.mkv` | Stream-copy video + audio → MP4; AAC fallback if audio is incompatible |
| `.mp4` | Faststart check and fix only (no re-encode) |
| `.avi`, `.mpg`, `.mpeg` | Stream-copy with AAC audio, or full re-encode fallback |
| `.wmv` | Re-encoded via libx264 + AAC (VC-1/WMV3 cannot be stream-copied into MP4) |

## Problem summary

At the end of each run the script prints a summary of any files that triggered a warning or error:

```
══════════════════════════════════════════════════════════
 PROBLEMS — 2 file(s) need attention
══════════════════════════════════════════════════════════
  [AUDIO: stream-copy remux failed; audio re-encoded to AAC]
    /Volumes/NAS/TV/Show/S01E01.mkv

  [ERROR: all encode strategies failed — file skipped]
    /Volumes/NAS/Movies/OldFilm.avi

══════════════════════════════════════════════════════════
```

| Label | Meaning |
|-------|---------|
| `AUDIO` | Stream-copy remux failed; audio was re-encoded to AAC. Output is likely fine but worth a spot-check. |
| `WARN` | Output MP4 is missing or empty — conversion did not complete successfully. |
| `ERROR` | All encode strategies failed; the source file was left untouched. |

## License

[MIT](LICENSE) — see the license file for the FFmpeg compatibility note.
