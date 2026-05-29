#!/usr/bin/env bash
set -euo pipefail

SRC="${1:-.}"
SRC="${SRC%/}"
DST="${2:-$SRC}"
DST="${DST%/}"
JOBS="${3:-2}"                     # Safe default for RAID/NFS
TMPROOT="/tmp/mp4work"
DELETE_SOURCE="${DELETE_SOURCE:-0}" # Set to 1 to remove source after successful conversion

# Honour pre-set env vars; otherwise ask interactively.
# MODE=remux    → convert MKV/legacy to MP4, skip faststart
# MODE=faststart → apply faststart to existing MP4s only, skip MKV/legacy
# MODE=both     → convert then faststart (original behaviour)
if [[ -z "${MODE:-}" ]]; then
  printf '\nProcessing mode:\n  1) Remux / re-encode only  (no faststart)\n  2) Faststart only          (existing MP4s — skips MKV/AVI/etc)\n  3) Both — remux + faststart  [default]\n' >&2
  read -r -p "  Choice [1/2/3]: " _choice </dev/tty 2>/dev/tty || _choice=3
  case "${_choice:-3}" in
    1) MODE=remux ;;
    2) MODE=faststart ;;
    *) MODE=both ;;
  esac
fi
export MODE

if [[ -z "${DELETE_SOURCE_SET:-}" ]]; then
  printf '\nDelete source file after successful conversion?\n  1) Keep source  [default]\n  2) Delete source\n' >&2
  read -r -p "  Choice [1/2]: " _del </dev/tty 2>/dev/tty || _del=1
  case "${_del:-1}" in
    2) DELETE_SOURCE=1 ;;
    *) DELETE_SOURCE=0 ;;
  esac
fi
export DELETE_SOURCE

FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"

mkdir -p "$TMPROOT"

PROBLEM_LOG="$(mktemp /tmp/remux_problems.XXXXXX)"
export PROBLEM_LOG
trap 'rm -f "$PROBLEM_LOG"' EXIT

log(){ printf '%s\n' "$*" >&2; }
ts(){ date +%H:%M:%S; }
problem(){ printf '%s\t%s\n' "$2" "$1" >> "$PROBLEM_LOG"; }

# Show minimal ffmpeg progress (speed + time) without full spam
ff_run() {
  # -stats prints a single updating line; -loglevel error keeps it clean
  "$FFMPEG" -nostdin -hide_banner -loglevel error -stats "$@"
}

# Returns 0 if "moov" appears before "mdat" in first few MB (faststart), else 1
is_faststart() {
  local f="$1"
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]
with open(p,'rb') as fh:
    head=fh.read(4*1024*1024)
moov=head.find(b'moov')
mdat=head.find(b'mdat')
sys.exit(0 if (moov!=-1 and mdat!=-1 and moov < mdat) else 1)
PY
}
export -f is_faststart

# Returns 0 if the primary video codec cannot be stream-copied into MP4
# (WMV/VC1 family and old MS-MPEG4 variants are container-incompatible)
needs_transcode_video() {
  local f="$1"
  local vcodec
  vcodec="$("$FFPROBE" -v error -select_streams v:0 \
      -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null | head -1)"
  case "$vcodec" in
    wmv1|wmv2|wmv3|vc1|msmpeg4v1|msmpeg4v2|msmpeg4v3|msmpeg4)
      return 0 ;;
    *)
      return 1 ;;
  esac
}
export -f needs_transcode_video

process_one_mkv() {
  local src="$1" dst="$2" file="$3"

  if [[ "${MODE:-both}" == "faststart" ]]; then
    log "$(ts) SKIP  : faststart-only mode — skipping MKV: $(basename "$file")"
    return 0
  fi

  local rel out base tmp tmpfs start
  rel="${file#"$src"/}"
  out="$dst/${rel%.mkv}.mp4"

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    log "$(ts) SKIP  : $out"
    return 0
  fi

  base="$(basename "${out%.mp4}")"
  tmp="$TMPROOT/${base}.$$.$RANDOM.mp4"
  tmpfs="$TMPROOT/${base}.$$.$RANDOM.fs.mp4"

  start="$(date +%s)"
  log "$(ts) START : $file"

  # 1) Remux locally
  log "$(ts) REMUX : -> $tmp"
  if ! ff_run -y -i "$file" -map 0:v -map 0:a -c copy "$tmp"; then
    rm -f "$tmp"
    log "$(ts) AUDIO : remux failed, AAC fallback"
    problem "$file" "AUDIO: stream-copy remux failed; audio re-encoded to AAC"
    ff_run -y -i "$file" -map 0:v -map 0:a -c:v copy -c:a aac -b:a 384k "$tmp"
  fi

  # 2) Faststart locally (skip if already faststart or in remux-only mode)
  if [[ "${MODE:-both}" == "remux" ]]; then
    log "$(ts) FAST  : skipped (remux-only mode)"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmp" "$out"
  elif is_faststart "$tmp"; then
    log "$(ts) FAST  : already faststart (skip)"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmp" "$out"
  else
    log "$(ts) FAST  : +faststart -> $tmpfs"
    ff_run -y -i "$tmp" -map 0 -c copy -movflags +faststart "$tmpfs"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmpfs" "$out"
    rm -f "$tmp" || true
  fi

  # 4) Export text subtitles to sidecar SRTs (quiet)
  log "$(ts) SUBS  : extracting (if any)"
  local subcodecs
  subcodecs="$("$FFPROBE" -v error -select_streams s \
      -show_entries stream=index,codec_name:stream_tags=language \
      -of csv=p=0 "$file" || true)"

  if [[ -n "$subcodecs" ]]; then
    local i=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local idx codec lang
      idx="$(echo "$line" | cut -d',' -f1)"
      codec="$(echo "$line" | cut -d',' -f2)"
      lang="$(echo "$line" | cut -d',' -f3)"
      lang="${lang:-und}"

      case "$codec" in
        subrip|ass|ssa|webvtt|mov_text|text)
          local srt="${out%.mp4}.sub$(printf '%02d' "$i").${lang}.srt"
          "$FFMPEG" -nostdin -hide_banner -loglevel error -y -i "$file" \
            -map 0:"$idx" -c:s srt "$srt" || true
          i=$((i+1))
          ;;
      esac
    done <<< "$subcodecs"
  fi

  # 5) Delete MKV if MP4 created
  if [[ -s "$out" ]]; then
    if [[ "$DELETE_SOURCE" == "1" ]]; then
      rm -f "$file"
      log "$(ts) DONE  : deleted MKV"
    else
      log "$(ts) DONE  : source kept (DELETE_SOURCE not set)"
    fi
  else
    log "$(ts) WARN  : MP4 missing/empty, NOT deleting MKV"
    problem "$file" "WARN: output MP4 missing or empty — conversion may have failed"
  fi

  local end elapsed
  end="$(date +%s)"
  elapsed=$((end-start))
  log "$(ts) TIME  : ${elapsed}s"
}

process_one_mp4() {
  local _src="$1" _dst="$2" file="$3"

  if [[ "${MODE:-both}" == "remux" ]]; then
    log "$(ts) SKIP  : remux-only mode — skipping MP4 faststart: $(basename "$file")"
    return 0
  fi

  # Only fix moov placement if needed
  if is_faststart "$file"; then
    log "$(ts) SKIPFAST: $file"
    return 0
  fi

  local start end elapsed tmpout
  start="$(date +%s)"
  log "$(ts) FASTMP4: $file"

  # Write temp next to the file (one big write to RAID), then atomic rename
  tmpout="${file}.faststart.tmp.mp4"
  rm -f "$tmpout" || true

  ff_run -y -i "$file" -map 0:v -map 0:a -map 0:s? -c copy -movflags +faststart "$tmpout"
  mv -f "$tmpout" "$file"

  end="$(date +%s)"
  elapsed=$((end-start))
  log "$(ts) TIME  : ${elapsed}s"
}

# Handler for legacy formats: AVI, MPG/MPEG, WMV
# - WMV/VC1 codecs are MP4-incompatible and are transcoded immediately (libx264 + AAC)
# - Everything else tries stream copy, then audio-transcode fallback, then full transcode
process_one_legacy() {
  local src="$1" dst="$2" file="$3"
  local ext="${file##*.}"

  if [[ "${MODE:-both}" == "faststart" ]]; then
    log "$(ts) SKIP  : faststart-only mode — skipping ${ext^^}: $(basename "$file")"
    return 0
  fi

  local rel out base tmp tmpfs start
  rel="${file#"$src"/}"
  out="$dst/${rel%.*}.mp4"

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    log "$(ts) SKIP  : $out"
    return 0
  fi

  base="$(basename "${out%.mp4}")"
  tmp="$TMPROOT/${base}.$$.$RANDOM.mp4"
  tmpfs="$TMPROOT/${base}.$$.$RANDOM.fs.mp4"

  start="$(date +%s)"
  log "$(ts) START : $file"

  # 1) Remux/encode locally
  if needs_transcode_video "$file"; then
    # WMV/VC1 etc: codec is not MP4-compatible, must re-encode video
    log "$(ts) XCODE : video transcode required (WMV/VC1) -> $tmp"
    if ! ff_run -y -i "$file" -map 0:v -map 0:a \
        -c:v libx264 -crf 18 -preset slow -c:a aac -b:a 384k "$tmp"; then
      rm -f "$tmp"
      log "$(ts) ERROR : transcode failed, skipping $file"
      return 1
    fi
  else
    log "$(ts) REMUX : audio->AAC -> $tmp"
    if ! ff_run -y -i "$file" -map 0:v -map 0:a -c:v copy -c:a aac -b:a 384k "$tmp"; then
      rm -f "$tmp"
      log "$(ts) XCODE : remux failed, full transcode fallback"
      if ! ff_run -y -i "$file" -map 0:v -map 0:a \
          -c:v libx264 -crf 18 -preset slow -c:a aac -b:a 384k "$tmp"; then
        rm -f "$tmp"
        log "$(ts) ERROR : all strategies failed, skipping $file"
        problem "$file" "ERROR: all encode strategies failed — file skipped"
        return 1
      fi
    fi
  fi

  # 2) Faststart (skip if remux-only mode or already faststart)
  if [[ "${MODE:-both}" == "remux" ]]; then
    log "$(ts) FAST  : skipped (remux-only mode)"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmp" "$out"
  elif is_faststart "$tmp"; then
    log "$(ts) FAST  : already faststart (skip)"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmp" "$out"
  else
    log "$(ts) FAST  : +faststart -> $tmpfs"
    ff_run -y -i "$tmp" -map 0 -c copy -movflags +faststart "$tmpfs"
    log "$(ts) MOVE  : -> $out"
    mv -f "$tmpfs" "$out"
    rm -f "$tmp" || true
  fi

  # 4) Delete source if MP4 created successfully
  if [[ -s "$out" ]]; then
    if [[ "$DELETE_SOURCE" == "1" ]]; then
      rm -f "$file"
      log "$(ts) DONE  : deleted ${ext^^}"
    else
      log "$(ts) DONE  : source kept (DELETE_SOURCE not set)"
    fi
  else
    log "$(ts) WARN  : MP4 missing/empty, NOT deleting source"
    problem "$file" "WARN: output MP4 missing or empty — conversion may have failed"
  fi

  local end elapsed
  end="$(date +%s)"
  elapsed=$((end-start))
  log "$(ts) TIME  : ${elapsed}s"
}

process_one() {
  local src="$1" dst="$2" file="$3"
  case "${file##*.}" in
    mkv|MKV)                          process_one_mkv    "$src" "$dst" "$file" ;;
    mp4|MP4)                          process_one_mp4    "$src" "$dst" "$file" ;;
    avi|AVI|mpg|MPG|mpeg|MPEG|wmv|WMV) process_one_legacy "$src" "$dst" "$file" ;;
  esac
}

export -f process_one process_one_mkv process_one_mp4 process_one_legacy \
           needs_transcode_video log ts ff_run is_faststart problem
export FFMPEG FFPROBE TMPROOT DELETE_SOURCE DELETE_SOURCE_SET MODE PROBLEM_LOG

log "SRC:  $SRC"
log "DST:  $DST"
log "JOBS: $JOBS"
log "TMP:  $TMPROOT"
log "MODE: $MODE"

find "$SRC" \
  \( -name '.Trashes' -o -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.TemporaryItems' \) -prune \
  -o \( -type f -not -name '._*' \
        \( -iname "*.mkv" -o -iname "*.mp4" \
           -o -iname "*.avi" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.wmv" \) \
        -print0 \) \
  | xargs -0 -n 1 -P "$JOBS" bash -c 'process_one "$@"' _ "$SRC" "$DST"

if [[ -s "$PROBLEM_LOG" ]]; then
  count="$(wc -l < "$PROBLEM_LOG" | tr -d ' ')"
  log ""
  log "══════════════════════════════════════════════════════════"
  log " PROBLEMS — ${count} file(s) need attention"
  log "══════════════════════════════════════════════════════════"
  while IFS=$'\t' read -r reason file; do
    log "  [${reason}]"
    log "    ${file}"
    log ""
  done < "$PROBLEM_LOG"
  log "══════════════════════════════════════════════════════════"
else
  log ""
  log "All files processed without errors."
fi
log "Done."
