#!/bin/bash

FFMPEG_RETRY_COUNT=${FFMPEG_RETRY_COUNT:-3}
FFMPEG_RETRY_DELAY=${FFMPEG_RETRY_DELAY:-1}

_ffmpeg_retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  exec_with_retry "$attempts" "$delay" "$@"
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
  ffmpeg_exec -hide_banner -filters 2>/dev/null | grep -q "$filter"
}

ffmpeg_command_preview() {
  local -a args=("$@")
  local preview
  preview=$(printf '%q ' ffmpeg "${args[@]}")
  preview=${preview% }
  printf '%s' "$preview"
}
