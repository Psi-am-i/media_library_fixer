# everything_2_faststart_mp4

Converts MKV, AVI, MPG, WMV, and MP4 files to faststart-compatible MP4 using FFmpeg. Built for media libraries on network drives — all transcoding happens locally on the machine running the script, then the output is moved to its destination, keeping network write traffic to a single sequential pass.

## Features

- **Three modes** — remux-only, faststart-only, or both
- **Smart remux** — stream-copies video and audio; falls back to AAC if the audio codec is incompatible with MP4
- **Faststart detection** — inspects the `moov`/`mdat` atom order and skips the faststart pass if it is already correct
- **Subtitle extraction** — exports text-based subtitle tracks (SRT, ASS, WebVTT, MOV_TEXT) to sidecar `.srt` files alongside the output
- **Legacy format support** — AVI, MPG/MPEG, WMV including VC-1/WMV3 codecs that cannot be stream-copied (re-encoded via libx264)
- **Parallel processing** — configurable job count for concurrent conversions via `xargs -P`
- **Local temp processing** — remux/encode runs in `/tmp/mp4work` before being moved to the destination, keeping the network path free of partial writes
- **Problem summary** — prints a consolidated list of files that need attention at the end of each run, so you don't have to trawl logs

## Requirements

- [`ffmpeg`](https://ffmpeg.org/download.html) and `ffprobe` in your `PATH` (or set via env vars)
- `python3` (standard library only — used for faststart atom detection)
- macOS or Linux

## Usage

```bash
./mkv_2_mp4_faststart.sh [SRC] [DST] [JOBS]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `SRC` | `.` | Source directory to scan recursively |
| `DST` | Same as `SRC` | Destination root for output MP4s (directory structure is preserved) |
| `JOBS` | `2` | Number of parallel conversion jobs |

The script prompts interactively for mode and delete-source preference on first run. Set the environment variables below to skip prompts for scripted/scheduled use.

### Environment variables

| Variable | Values | Description |
|----------|--------|-------------|
| `MODE` | `remux` / `faststart` / `both` | Processing mode — skips the interactive prompt |
| `DELETE_SOURCE` | `0` / `1` | Remove source file after a successful conversion |
| `DELETE_SOURCE_SET` | any non-empty value | Set to skip the delete-source prompt |
| `FFMPEG` | path | Override the `ffmpeg` binary location |
| `FFPROBE` | path | Override the `ffprobe` binary location |

### Examples

```bash
# Interactive — prompts for mode and whether to keep or delete the source
./mkv_2_mp4_faststart.sh /Volumes/NAS/TV

# Remux all files in one directory to another, 4 parallel jobs, non-interactive
MODE=remux DELETE_SOURCE=0 DELETE_SOURCE_SET=1 \
  ./mkv_2_mp4_faststart.sh /Volumes/NAS/TV /Volumes/Output/TV 4

# Faststart-only pass over an existing MP4 library (in-place)
MODE=faststart DELETE_SOURCE=0 DELETE_SOURCE_SET=1 \
  ./mkv_2_mp4_faststart.sh /Volumes/NAS/Movies
```

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
