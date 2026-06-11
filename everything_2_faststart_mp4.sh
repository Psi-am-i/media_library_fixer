#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# everything_2_faststart_mp4.sh — Convert/remux video files to faststart MP4
#
# USAGE:
#   ./everything_2_faststart_mp4.sh [SRC]
#
#   SRC   Directory to scan (default: current directory)
#
# GRACEFUL STOP:
#   touch /tmp/mp4_stop      — finish current file(s), skip the rest
#   rm /tmp/mp4_stop         — clear the stop flag to resume/re-run
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SRC="${1:-.}"
SRC="${SRC%/}"
TMPROOT="/tmp/mp4work"

# ── Interactive prompts ───────────────────────────────────────────────────────

printf '\nProcessing mode:\n  1) Remux / re-encode only  (MKV/AVI/WMV → MP4, no faststart pass)\n  2) Faststart only          (fix moov placement on existing MP4s)\n  3) Both — remux then faststart  [default]\n' >&2
read -r -p "  Choice [1/2/3]: " _mchoice </dev/tty 2>/dev/tty || _mchoice=3
case "${_mchoice:-3}" in
  1) MODE=remux ;;
  2) MODE=faststart ;;
  *) MODE=both ;;
esac
export MODE

printf '\nWhere should the new file be written?\n  1) Replace source in place  [default]\n  2) Write to a separate folder\n' >&2
read -r -p "  Choice [1/2]: " _ochoice </dev/tty 2>/dev/tty || _ochoice=1
case "${_ochoice:-1}" in
  2)
    OUTPUT_MODE=separate
    printf '\nDestination folder for new files?\n  (default: %s/new versions)\n' "$SRC" >&2
    read -r -p "  Path: " _opath </dev/tty 2>/dev/tty || _opath=""
    OUTPUT_DIR="${_opath:-$SRC/new versions}"
    printf '\nFolder structure in destination?\n  1) Mirror source folder structure  [default]\n  2) Flat — all files in destination root\n' >&2
    read -r -p "  Choice [1/2]: " _fchoice </dev/tty 2>/dev/tty || _fchoice=1
    case "${_fchoice:-1}" in
      2) OUTPUT_FLAT=1 ;;
      *) OUTPUT_FLAT=0 ;;
    esac
    ;;
  *)
    OUTPUT_MODE=inplace
    OUTPUT_DIR="$SRC"
    OUTPUT_FLAT=0
    ;;
esac
export OUTPUT_MODE OUTPUT_DIR OUTPUT_FLAT

printf '\nWhat should happen to the original file?\n  1) Archive (move to a folder)  [default]\n  2) Delete\n  3) Leave it where it is\n' >&2
read -r -p "  Choice [1/2/3]: " _schoice </dev/tty 2>/dev/tty || _schoice=1
case "${_schoice:-1}" in
  2) SOURCE_ACTION=delete ;;
  3) SOURCE_ACTION=keep ;;
  *) SOURCE_ACTION=archive ;;
esac

if [[ "$SOURCE_ACTION" == "archive" ]]; then
  printf '\nWhere should originals be archived?\n  (default: %s/originals)\n' "$SRC" >&2
  read -r -p "  Path: " _apath </dev/tty 2>/dev/tty || _apath=""
  ARCHIVE_DIR="${_apath:-$SRC/originals}"
else
  ARCHIVE_DIR=""
fi
export SOURCE_ACTION ARCHIVE_DIR

printf '\nParallel jobs?\n  1) 1 job\n  2) 2 jobs  [default]\n  3) 4 jobs\n' >&2
read -r -p "  Choice [1/2/3]: " _jchoice </dev/tty 2>/dev/tty || _jchoice=2
case "${_jchoice:-2}" in
  1) JOBS=1 ;;
  3) JOBS=4 ;;
  *) JOBS=2 ;;
esac
export JOBS

# ── Setup ─────────────────────────────────────────────────────────────────────

FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"

# Transcode bitrate caps — used as -maxrate ceiling when source bitrate is unknown
XCODE_BITRATE_CAP_HD=8000    # kbps, for content < 3840px wide
XCODE_BITRATE_CAP_4K=20000   # kbps, for 4K content

mkdir -p "$TMPROOT"

PROBLEM_LOG="$(mktemp /tmp/remux_problems.XXXXXX)"
STOP_FILE="/tmp/mp4_stop"
export PROBLEM_LOG STOP_FILE
trap 'rm -f "$PROBLEM_LOG"' EXIT

TTY=/dev/tty
log(){ printf '%s\n' "$*" > "$TTY"; }
ts(){ date +%H:%M:%S; }
problem(){ printf '%s\t%s\n' "$2" "$1" >> "$PROBLEM_LOG"; }
fsize(){ du -sh "$1" 2>/dev/null | awk '{print $1}'; }
sname(){ local b; b="$(basename "$1")"; printf '%s' "${b%.*}"; }

check_stop_requested() {
  if [[ -f "$STOP_FILE" ]]; then
    log "$(ts) STOP  : stop file found ($STOP_FILE) — skipping remaining files"
    return 0
  fi
  return 1
}

# Progress-aware ffmpeg wrapper.
#   ff_run_progress LABEL DURATION_SECS START_TS [ffmpeg args...]
ff_run_progress() {
  local label="$1" dur_secs="$2" start_ts="$3"
  shift 3

  local _e _prog _rc
  _e=$(mktemp /tmp/fferr.XXXXXX)
  _prog=$(mktemp /tmp/ffprog.XXXXXX)

  local interval offset monitor_pid
  if [[ "${JOBS:-2}" -le 1 ]]; then
    interval=10; offset=0
  else
    interval=20
    offset=$(( $(printf '%s' "$label" | cksum | awk '{print $1}') % interval ))
  fi

  ( sleep "$offset"
    while true; do
      sleep "$interval"
      [[ -f "$_prog" ]] || break
      local out_time_us speed bitrate elapsed
      out_time_us=$(grep '^out_time_us=' "$_prog" 2>/dev/null | tail -1 | cut -d= -f2)
      speed=$(grep       '^speed='       "$_prog" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
      bitrate=$(grep     '^bitrate='     "$_prog" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
      elapsed=$(( $(date +%s) - start_ts ))
      if [[ -n "$out_time_us" && "$out_time_us" =~ ^[0-9]+$ && \
            -n "$dur_secs"    && "$dur_secs"    =~ ^[0-9]+$  && \
            "$dur_secs" -gt 0 ]]; then
        local done_secs=$(( out_time_us / 1000000 ))
        local pct
        pct=$(python3 -c "print(f'{min($done_secs/$dur_secs*100,100):.1f}')")
        local eta_str=""
        if [[ "$elapsed" -gt 2 && $(python3 -c "print(1 if $done_secs>0 else 0)") == "1" ]]; then
          local remain
          remain=$(python3 -c "
done=$done_secs; total=$dur_secs; el=$elapsed
if done>0:
    eta=int(el/done*(total-done))
    m,s=divmod(eta,60); h,m=divmod(m,60)
    print(f'{h}h{m:02d}m' if h else f'{m}m{s:02d}s')
else:
    print('?')
")
          eta_str="  ETA=${remain}"
        fi
        log "$(ts)  ...  : ${pct}%  speed=${speed:-?}  bitrate=${bitrate:-?}  elapsed=${elapsed}s${eta_str}  — ${label}"
      else
        log "$(ts)  ...  : elapsed=${elapsed}s  speed=${speed:-?}  bitrate=${bitrate:-?}  — ${label}"
      fi
    done ) &
  monitor_pid=$!

  "$FFMPEG" -nostdin -hide_banner -loglevel error \
    -progress "$_prog" -stats_period 2 \
    "$@" 2>"$_e"
  _rc=$?

  kill "$monitor_pid" 2>/dev/null
  wait "$monitor_pid" 2>/dev/null || true

  if [[ -s "$_e" && $_rc -ne 0 ]]; then
    while IFS= read -r _l; do
      _l=$(printf '%s' "$_l" | sed $'s/\033\\[[0-9;]*m//g')
      [[ -z "$_l" ]] && continue
      printf '%s\n' "$(ts)   ! ${_l}" > "$TTY"
    done < "$_e"
  fi
  rm -f "$_e" "$_prog"
  return "$_rc"
}

# Plain wrapper — no progress monitoring (faststart pass, subtitle extract)
ff_run() {
  local _e _rc
  _e=$(mktemp /tmp/fferr.XXXXXX)
  "$FFMPEG" -nostdin -hide_banner -loglevel error "$@" 2>"$_e"
  _rc=$?
  if [[ -s "$_e" && $_rc -ne 0 ]]; then
    while IFS= read -r _l; do
      _l=$(printf '%s' "$_l" | sed $'s/\033\\[[0-9;]*m//g')
      [[ -z "$_l" ]] && continue
      printf '%s\n' "$(ts)   ! ${_l}" > "$TTY"
    done < "$_e"
  fi
  rm -f "$_e"
  return "$_rc"
}

# Returns 0 if "moov" appears before "mdat" in first few MB (already faststart)
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

probe_video_field() {
  "$FFPROBE" -v error -select_streams v:0 \
    -show_entries "stream=$2" -of csv=p=0 "$1" | head -1
}
export -f probe_video_field

probe_container_bitrate() {
  "$FFPROBE" -v error -show_entries format=bit_rate -of csv=p=0 "$1" | head -1
}
export -f probe_container_bitrate

# Returns 0 if the primary video codec cannot be stream-copied into MP4
needs_transcode_video() {
  local f="$1"
  local vcodec
  vcodec="$("$FFPROBE" -v error -select_streams v:0 \
      -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null | head -1)"
  case "$vcodec" in
    wmv1|wmv2|wmv3|vc1|msmpeg4v1|msmpeg4v2|msmpeg4v3|msmpeg4) return 0 ;;
    *) return 1 ;;
  esac
}
export -f needs_transcode_video

# ── Shared source-handling after successful output ────────────────────────────
handle_source() {
  local file="$1" out="$2" rel="$3" elapsed="$4"
  local n; n="$(sname "$file")"
  case "${SOURCE_ACTION:-archive}" in
    delete)
      [[ "$file" != "$out" ]] && rm -f "$file"
      log "$(ts) DONE  : ${elapsed}s  [$(fsize "$out")]  $n  (original deleted)"
      ;;
    archive)
      local arc_rel arc_dest
      arc_rel="$(dirname "$rel")"
      arc_dest="${ARCHIVE_DIR}${arc_rel:+/$arc_rel}"
      mkdir -p "$arc_dest"
      [[ "$file" != "$out" ]] && mv -f "$file" "$arc_dest/$(basename "$file")"
      log "$(ts) DONE  : ${elapsed}s  [$(fsize "$out")]  $n  (original → $(basename "$ARCHIVE_DIR"))"
      ;;
    keep)
      log "$(ts) DONE  : ${elapsed}s  [$(fsize "$out")]  $n"
      ;;
  esac
}
export -f handle_source

# ── Compute output path ───────────────────────────────────────────────────────
output_path() {
  local src="$1" file="$2" new_ext="$3"
  local rel; rel="${file#"$src"/}"
  if [[ "${OUTPUT_MODE:-inplace}" == "separate" ]]; then
    if [[ "${OUTPUT_FLAT:-0}" == "1" ]]; then
      echo "${OUTPUT_DIR}/$(basename "${rel%.*}")${new_ext}"
    else
      echo "${OUTPUT_DIR}/${rel%.*}${new_ext}"
    fi
  else
    echo "${src}/${rel%.*}${new_ext}"
  fi
}
export -f output_path

# ── Process MKV ──────────────────────────────────────────────────────────────
process_one_mkv() {
  local src="$1" file="$2"

  if [[ "${MODE:-both}" == "faststart" ]]; then return 0; fi

  local rel out n
  rel="${file#"$src"/}"
  out="$(output_path "$src" "$file" .mp4)"
  n="$(sname "$file")"

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    log "$(ts) SKIP  : already converted — $n"
    return 0
  fi

  if check_stop_requested; then return 0; fi

  local base tmp tmpfs start
  base="$(basename "${out%.mp4}")"
  tmp="$TMPROOT/${base}.$$.$RANDOM.mp4"
  tmpfs="$TMPROOT/${base}.$$.$RANDOM.fs.mp4"
  start="$(date +%s)"

  log "$(ts) START : [$(fsize "$file")]  $n"

  local dur_raw dur_secs
  dur_raw="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | head -1)"
  if [[ "$dur_raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    dur_secs="$(python3 -c "print(int(float('$dur_raw')))")"
  else
    dur_secs=0
  fi

  if needs_transcode_video "$file"; then
    log "$(ts) XCODE : WMV/VC1 in MKV — $n"
    problem "$file" "VIDEO: codec not MP4-compatible; transcoded to H.264+AAC"
    local src_bps xwidth maxrate bufsize
    src_bps="$(probe_video_field "$file" bit_rate)"
    xwidth="$(probe_video_field "$file" width)"
    [[ -z "$src_bps" || "$src_bps" == "N/A" ]] && src_bps="$(probe_container_bitrate "$file")"
    if [[ -n "$src_bps" && "$src_bps" =~ ^[0-9]+$ ]]; then
      maxrate="$(( src_bps / 1000 ))k"
    else
      maxrate="$( [[ "${xwidth:-0}" -ge 3840 ]] && echo "${XCODE_BITRATE_CAP_4K}k" || echo "${XCODE_BITRATE_CAP_HD}k" )"
      log "$(ts) WARN  : could not probe source bitrate, using cap ($maxrate) — $n"
    fi
    bufsize="$(python3 -c "print(str(int('${maxrate%k}') * 2) + 'k')")"
    if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a \
        -c:v libx264 -crf 18 -preset slow -maxrate "$maxrate" -bufsize "$bufsize" \
        -c:a aac -b:a 384k "$tmp"; then
      rm -f "$tmp"
      log "$(ts) ERROR : transcode failed — $n"
      problem "$file" "ERROR: transcode failed"
      return 1
    fi
  else
    log "$(ts) REMUX : $n"
    if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a -c copy "$tmp"; then
      rm -f "$tmp"
      log "$(ts) AUDIO : stream-copy failed, re-encoding audio — $n"
      problem "$file" "AUDIO: stream-copy remux failed; audio re-encoded to AAC"
      if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a -c:v copy -c:a aac -b:a 384k "$tmp"; then
        rm -f "$tmp"
        log "$(ts) ERROR : all remux strategies failed — $n"
        problem "$file" "ERROR: all remux strategies failed"
        return 1
      fi
    fi
  fi

  if [[ "${MODE:-both}" == "remux" ]] || is_faststart "$tmp"; then
    mv -f "$tmp" "$out"
  else
    log "$(ts) FAST  : $n"
    ff_run -y -i "$tmp" -map 0 -c copy -movflags +faststart "$tmpfs"
    mv -f "$tmpfs" "$out"
    rm -f "$tmp" || true
  fi

  # Extract text subtitles to sidecar SRTs
  local subcodecs
  subcodecs="$("$FFPROBE" -v error -select_streams s \
      -show_entries stream=index,codec_name:stream_tags=language \
      -of csv=p=0 "$file" || true)"

  if [[ -n "$subcodecs" ]]; then
    local i=0 srt_args=()
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
          srt_args+=(-map "0:${idx}" -c:s srt "$srt")
          i=$((i+1))
          ;;
      esac
    done <<< "$subcodecs"
    if [[ "${#srt_args[@]}" -gt 0 ]]; then
      "$FFMPEG" -nostdin -hide_banner -loglevel error -y -i "$file" "${srt_args[@]}" || true
      log "$(ts) SUBS  : $i track(s) — $n"
    fi
  fi

  local end elapsed
  end="$(date +%s)"; elapsed=$((end-start))

  if [[ -s "$out" ]]; then
    handle_source "$file" "$out" "$rel" "$elapsed"
  else
    log "$(ts) WARN  : output MP4 empty, keeping source — $n"
    problem "$file" "WARN: output MP4 missing or empty — conversion may have failed"
  fi
}

# ── Process existing MP4 (faststart fix only) ────────────────────────────────
process_one_mp4() {
  local src="$1" file="$2"

  if [[ "${MODE:-both}" == "remux" ]]; then return 0; fi
  if is_faststart "$file"; then return 0; fi

  if check_stop_requested; then return 0; fi

  local start n tmpout
  start="$(date +%s)"
  n="$(sname "$file")"
  log "$(ts) FAST  : [$(fsize "$file")]  $n"

  tmpout="${file}.faststart.tmp.mp4"
  rm -f "$tmpout" || true
  ff_run -y -i "$file" -map 0:v -map 0:a? -map 0:s? -c copy -movflags +faststart "$tmpout"
  mv -f "$tmpout" "$file"

  local end elapsed
  end="$(date +%s)"; elapsed=$((end-start))
  log "$(ts) DONE  : ${elapsed}s  [$(fsize "$file")]  $n"
}

# ── Process legacy formats (AVI, MPG, WMV) ───────────────────────────────────
process_one_legacy() {
  local src="$1" file="$2"

  if [[ "${MODE:-both}" == "faststart" ]]; then return 0; fi

  local rel out n
  rel="${file#"$src"/}"
  out="$(output_path "$src" "$file" .mp4)"
  n="$(sname "$file")"

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    log "$(ts) SKIP  : already converted — $n"
    return 0
  fi

  if check_stop_requested; then return 0; fi

  local base tmp tmpfs start
  base="$(basename "${out%.mp4}")"
  tmp="$TMPROOT/${base}.$$.$RANDOM.mp4"
  tmpfs="$TMPROOT/${base}.$$.$RANDOM.fs.mp4"
  start="$(date +%s)"

  log "$(ts) START : [$(fsize "$file")]  $n"

  local dur_raw dur_secs
  dur_raw="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | head -1)"
  if [[ "$dur_raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    dur_secs="$(python3 -c "print(int(float('$dur_raw')))")"
  else
    dur_secs=0
  fi

  local src_bps xwidth maxrate bufsize
  src_bps="$(probe_video_field "$file" bit_rate)"
  xwidth="$(probe_video_field "$file" width)"
  [[ -z "$src_bps" || "$src_bps" == "N/A" ]] && src_bps="$(probe_container_bitrate "$file")"
  if [[ -n "$src_bps" && "$src_bps" =~ ^[0-9]+$ ]]; then
    maxrate="$(( src_bps / 1000 ))k"
  else
    maxrate="$( [[ "${xwidth:-0}" -ge 3840 ]] && echo "${XCODE_BITRATE_CAP_4K}k" || echo "${XCODE_BITRATE_CAP_HD}k" )"
    log "$(ts) WARN  : could not probe source bitrate, using cap ($maxrate) — $n"
  fi
  bufsize="$(python3 -c "print(str(int('${maxrate%k}') * 2) + 'k')")"

  if needs_transcode_video "$file"; then
    log "$(ts) XCODE : WMV/VC1 — $n"
    if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a \
        -c:v libx264 -crf 18 -preset slow -maxrate "$maxrate" -bufsize "$bufsize" \
        -c:a aac -b:a 384k "$tmp"; then
      rm -f "$tmp"
      log "$(ts) ERROR : transcode failed — $n"
      return 1
    fi
  else
    log "$(ts) REMUX : $n"
    if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a \
        -c:v copy -c:a aac -b:a 384k "$tmp"; then
      rm -f "$tmp"
      log "$(ts) XCODE : remux failed, transcoding — $n"
      if ! ff_run_progress "$n" "$dur_secs" "$start" -y -i "$file" -map 0:v -map 0:a \
          -c:v libx264 -crf 18 -preset slow -maxrate "$maxrate" -bufsize "$bufsize" \
          -c:a aac -b:a 384k "$tmp"; then
        rm -f "$tmp"
        log "$(ts) ERROR : all strategies failed — $n"
        problem "$file" "ERROR: all encode strategies failed — file skipped"
        return 1
      fi
    fi
  fi

  if [[ "${MODE:-both}" == "remux" ]] || is_faststart "$tmp"; then
    mv -f "$tmp" "$out"
  else
    log "$(ts) FAST  : $n"
    ff_run -y -i "$tmp" -map 0 -c copy -movflags +faststart "$tmpfs"
    mv -f "$tmpfs" "$out"
    rm -f "$tmp" || true
  fi

  local end elapsed
  end="$(date +%s)"; elapsed=$((end-start))

  if [[ -s "$out" ]]; then
    handle_source "$file" "$out" "$rel" "$elapsed"
  else
    log "$(ts) WARN  : output MP4 empty, keeping source — $n"
    problem "$file" "WARN: output MP4 missing or empty — conversion may have failed"
  fi
}

process_one() {
  local src="$1" file="$2"
  case "${file##*.}" in
    mkv|MKV)                           process_one_mkv    "$src" "$file" ;;
    mp4|MP4)                           process_one_mp4    "$src" "$file" ;;
    avi|AVI|mpg|MPG|mpeg|MPEG|wmv|WMV) process_one_legacy "$src" "$file" ;;
  esac
}

export -f process_one process_one_mkv process_one_mp4 process_one_legacy handle_source output_path \
           needs_transcode_video probe_video_field probe_container_bitrate \
           log ts ff_run ff_run_progress is_faststart problem fsize sname \
           check_stop_requested
export FFMPEG FFPROBE TMPROOT SOURCE_ACTION ARCHIVE_DIR \
       OUTPUT_MODE OUTPUT_DIR OUTPUT_FLAT MODE PROBLEM_LOG STOP_FILE TTY JOBS \
       XCODE_BITRATE_CAP_HD XCODE_BITRATE_CAP_4K

log ""
log "SRC:       $SRC"
log "MODE:      $MODE"
log "OUTPUT:    $( [[ "$OUTPUT_MODE" == "separate" ]] && echo "$OUTPUT_DIR ($( [[ $OUTPUT_FLAT == 1 ]] && echo flat || echo mirrored ))" || echo "in place" )"
log "ORIGINALS: $( case "$SOURCE_ACTION" in archive) echo "archive → $ARCHIVE_DIR" ;; delete) echo "delete" ;; keep) echo "keep" ;; esac )"
log "JOBS:      $JOBS"
log "STOP:      touch $STOP_FILE   (finish current file, skip the rest)"
log "           rm $STOP_FILE      (clear stop flag to re-run)"
log ""

find "$SRC" \
  \( -name '.Trashes' -o -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.TemporaryItems' \
     -o -name 'originals' -o -name 'new versions' -o -name 'Library' \) -prune \
  -o \( -type f -not -name '._*' \
        \( -iname "*.mkv" -o -iname "*.mp4" \
           -o -iname "*.avi" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.wmv" \) \
        -print0 \) \
  | xargs -0 -n 1 -P "$JOBS" bash -c 'process_one "$@"' _ "$SRC"

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
