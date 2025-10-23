#!/bin/bash

FFMPEG_RETRY_COUNT=${FFMPEG_RETRY_COUNT:-3}
FFMPEG_RETRY_DELAY=${FFMPEG_RETRY_DELAY:-1}

_ffmpeg_retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  exec_with_retry "$attempts" "$delay" "$@"
  return $?
}

ffmpeg_exec() {
  local attempts="${FFMPEG_RETRY_COUNT:-3}"
  local delay="${FFMPEG_RETRY_DELAY:-1}"
  _ffmpeg_retry "$attempts" "$delay" ffmpeg "$@"
}

ffprobe_exec() {
  local attempts="${FFMPEG_RETRY_COUNT:-3}"
  local delay="${FFMPEG_RETRY_DELAY:-1}"
  _ffmpeg_retry "$attempts" "$delay" ffprobe "$@"
}

ffmpeg_supports_filter() {
  local filter="$1"
  ffmpeg_exec -hide_banner -filters 2>/dev/null | grep -qF "$filter"
}

ffmpeg_command_preview() {
  local -a args=("$@")
  local preview
  preview=$(printf '%q ' ffmpeg "${args[@]}")
  preview=${preview% }
  printf '%s' "$preview"
}

ffmpeg_media_duration_raw() {
  local source="$1"
  ffprobe_exec -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$source" 2>/dev/null || true
}

ffmpeg_media_duration_seconds() {
  local source="$1"
  local raw
  raw=$(ffmpeg_media_duration_raw "$source")
  if [ -z "$raw" ] || [ "$raw" = "N/A" ]; then
    printf ''
    return 1
  fi
  awk -v d="$raw" 'BEGIN{d+=0;if(d<0)d=0;printf "%.6f",d}' 2>/dev/null || printf ''
}

ffmpeg_audio_stream_info() {
  local source="$1" codec
  codec=$(ffprobe_exec -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$source" 2>/dev/null || true)
  codec=$(printf '%s' "$codec" | tr '[:upper:]' '[:lower:]')
  if [ -n "$codec" ]; then
    printf '%s' "$codec"
    return 0
  fi
  if ffprobe_exec -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$source" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
