#!/bin/bash
# modules/time_utils.sh — безопасная обработка временных меток для Uniclon

_clip_start_to_seconds() {
  local raw="${1:-}"
  awk -v t="$raw" '
    function fail(){ exit 1 }
    BEGIN {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      if (t == "" || t ~ /^-/) fail()
      n=split(t, parts, ":")
      if (n < 1 || n > 3) fail()
      if (n == 1) {
        if (t !~ /^([0-9]+(\.[0-9]+)?|\.[0-9]+)$/) fail()
        printf "%.6f", t + 0
        exit 0
      }
      total = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] !~ /^([0-9]+(\.[0-9]+)?|\.[0-9]+)$/) fail()
      }
      if (n == 2) {
        total = parts[1]*60 + parts[2]
      } else {
        total = parts[1]*3600 + parts[2]*60 + parts[3]
      }
      printf "%.6f", total + 0
    }'
}

ffmpeg_time_to_seconds() {
  local raw="$1"
  awk -v t="$raw" '
    function fail(){ exit 1 }
    BEGIN{
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      if (t == "" || t ~ /^-/) fail()
      n=split(t, parts, ":")
      if (n == 1) {
        if (t !~ /^[0-9]+(\.[0-9]+)?$/) fail()
        printf "%.6f", t + 0
        exit 0
      }
      if (n < 2 || n > 3) fail()
      total = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] !~ /^[0-9]+(\.[0-9]+)?$/) fail()
      }
      if (n == 2) {
        total = parts[1] * 60 + parts[2]
      } else {
        total = parts[1] * 3600 + parts[2] * 60 + parts[3]
      }
      printf "%.6f", total + 0
    }'
}

normalize_ss_value() {
  local raw="$1"
  local fallback="$2"
  local label="$3"
  local context="$4"
  local sanitized candidate="" final token_count=0

  sanitized=$(printf '%s' "$raw" | tr -s '[:space:]' ' ')
  sanitized=${sanitized# }
  sanitized=${sanitized% }

  if [ -n "$sanitized" ]; then
    local old_ifs="$IFS"
    local tokens=()
    IFS=' '
    read -r -a tokens <<<"$sanitized"
    IFS="$old_ifs"
    token_count=${#tokens[@]}
    if [ $token_count -gt 0 ]; then
      candidate="${tokens[0]}"
    fi
  fi

  local context_prefix=""
  if [ -n "$context" ]; then
    context_prefix="[$context] "
  fi

  if [ -z "$candidate" ]; then
    echo "⚠️ ${context_prefix}Пустое значение ${label} для -ss, используется ${fallback}" >&2
    final="$fallback"
  else
    if [ $token_count -gt 1 ]; then
      echo "⚠️ ${context_prefix}Обнаружено несколько значений ${label} для -ss: '${sanitized}'. Используется '${candidate}'" >&2
    fi
    if ffmpeg_time_to_seconds "$candidate" >/dev/null 2>&1; then
      final="$candidate"
    else
      echo "⚠️ ${context_prefix}Некорректное значение ${label} для -ss: '${candidate}', используется ${fallback}" >&2
      final="$fallback"
    fi
  fi

  if ! ffmpeg_time_to_seconds "$final" >/dev/null 2>&1; then
    final="0.000"
  fi

  printf '%s' "$final"
}

normalize_duration_value() {
  local raw="$1"
  local fallback="$2"
  local label="$3"
  local context="$4"
  local sanitized candidate="" final token_count=0
  local fallback_value fallback_candidate="" fallback_seconds="" candidate_seconds=""

  sanitized=$(printf '%s' "$raw" | tr -s '[:space:]' ' ')
  sanitized=${sanitized# }
  sanitized=${sanitized% }

  if [ -n "$sanitized" ]; then
    local old_ifs="$IFS"
    local tokens=()
    IFS=' '
    read -r -a tokens <<<"$sanitized"
    IFS="$old_ifs"
    token_count=${#tokens[@]}
    if [ $token_count -gt 0 ]; then
      candidate="${tokens[0]}"
    fi
  fi

  fallback_value=$(printf '%s' "$fallback" | tr -s '[:space:]' ' ')
  fallback_value=${fallback_value# }
  fallback_value=${fallback_value% }
  if [ -n "$fallback_value" ]; then
    local old_fallback_ifs="$IFS"
    IFS=' '
    read -r fallback_candidate _ <<<"$fallback_value"
    IFS="$old_fallback_ifs"
  fi
  if ffmpeg_time_to_seconds "$fallback_candidate" >/dev/null 2>&1; then
    fallback_seconds=$(ffmpeg_time_to_seconds "$fallback_candidate" 2>/dev/null || echo "")
    if [ -z "$fallback_seconds" ] || ! awk -v v="$fallback_seconds" 'BEGIN{exit (v>0?0:1)}'; then
      fallback_candidate="0.300"
    fi
  else
    fallback_candidate="0.300"
  fi

  local context_prefix=""
  if [ -n "$context" ]; then
    context_prefix="[$context] "
  fi

  if [ -z "$candidate" ]; then
    echo "⚠️ ${context_prefix}Пустое значение ${label} для -t, используется ${fallback_candidate}" >&2
    final="$fallback_candidate"
  else
    if [ $token_count -gt 1 ]; then
      echo "⚠️ ${context_prefix}Обнаружено несколько значений ${label} для -t: '${sanitized}'. Используется '${candidate}'" >&2
    fi
    if ffmpeg_time_to_seconds "$candidate" >/dev/null 2>&1; then
      candidate_seconds=$(ffmpeg_time_to_seconds "$candidate" 2>/dev/null || echo "")
      if [ -n "$candidate_seconds" ] && awk -v v="$candidate_seconds" 'BEGIN{exit (v>0?0:1)}'; then
        final="$candidate"
      else
        echo "⚠️ ${context_prefix}Некорректная длительность ${label} для -t: '${candidate}', используется ${fallback_candidate}" >&2
        final="$fallback_candidate"
      fi
    else
      echo "⚠️ ${context_prefix}Некорректное значение ${label} для -t: '${candidate}', используется ${fallback_candidate}" >&2
      final="$fallback_candidate"
    fi
  fi

  if ! ffmpeg_time_to_seconds "$final" >/dev/null 2>&1; then
    final="$fallback_candidate"
  fi

  printf '%s' "$final"
}

clip_start() {
  local value="${1:-0.000}"
  local fallback="${2:-0.000}"
  local label="${3:-clip_start}"
  local copy_id="${4:-}"
  local seconds fallback_seconds
  if seconds=$(_clip_start_to_seconds "$value" 2>/dev/null); then
    printf "%.3f" "$seconds"
    return 0
  fi
  if ! fallback_seconds=$(_clip_start_to_seconds "$fallback" 2>/dev/null); then
    fallback_seconds="0.000"
  fi
  echo "⚠️ [$label] Некорректное значение '$value' — используется fallback=${fallback_seconds} (${copy_id})"
  printf "%.3f" "$fallback_seconds"
}

duration() {
  normalize_duration_value "$@"
}

date_supports_d_flag() {
  date -u -d "1970-01-01" >/dev/null 2>&1
}

date_supports_v_flag() {
  date -v-1d +%Y >/dev/null 2>&1
}

iso_to_epoch() {
  local iso="$1"
  if date_supports_d_flag; then
    date -u -d "$iso" +%s
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s
  fi
}

epoch_to_iso() {
  local epoch="$1"
  if date_supports_d_flag; then
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

jitter_iso_timestamp() {
  local iso="$1"
  local minutes=$(rand_int 1 5)
  local seconds=$((minutes * 60))
  if [ "$(rand_int 0 1)" -eq 0 ]; then
    seconds=$((-seconds))
  fi
  local epoch
  epoch=$(iso_to_epoch "$iso")
  epoch=$((epoch + seconds))
  epoch_to_iso "$epoch"
}

generate_iso_timestamp() {
  local days_ago seconds_offset
  days_ago=$(rand_int 3 14)
  seconds_offset=$(rand_int 0 86399)
  if date_supports_d_flag; then
    date -u -d "${days_ago} days ago + ${seconds_offset} seconds" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -v -"${days_ago}"d -v +"${seconds_offset}"S +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

format_past_timestamp() {
  local fmt="$1"
  local days="$2"
  local hours="$3"
  local minutes="$4"
  local seconds="$5"

  if date_supports_v_flag; then
    date -v-"${days}"d -v-"${hours}"H -v-"${minutes}"M -v-"${seconds}"S +"$fmt"
    return
  fi

  if date_supports_d_flag; then
    local spec="-${days} days -${hours} hours -${minutes} minutes -${seconds} seconds"
    date -u -d "$spec" +"$fmt"
    return
  fi

  PY_FMT="$fmt" PY_DAYS="$days" PY_HOURS="$hours" PY_MINUTES="$minutes" PY_SECONDS="$seconds" python3 - <<'PY'
import datetime
import os

fmt = os.environ['PY_FMT']
days = int(os.environ['PY_DAYS'])
hours = int(os.environ['PY_HOURS'])
minutes = int(os.environ['PY_MINUTES'])
seconds = int(os.environ['PY_SECONDS'])
dt = datetime.datetime.utcnow() - datetime.timedelta(
    days=days, hours=hours, minutes=minutes, seconds=seconds
)
print(dt.strftime(fmt))
PY
}

timestamp_offset() {
  local fmt="$1"
  local days="$2"
  local hours="$3"
  local minutes="$4"
  local seconds="$5"
  format_past_timestamp "$fmt" "$days" "$hours" "$minutes" "$seconds"
}
