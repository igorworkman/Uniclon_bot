#!/bin/bash
# process_protective_v1.6.sh (macOS совместимая версия)
# Делает N уникальных копий из одного видео, сохраняет в "Новая папка/"
set -euo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DIR="${BASE_DIR}/checks"
LOW_UNIQUENESS_FLAG="${CHECK_DIR}/low_uniqueness.flag"

# REGION AI: default output directories
OUTPUT_DIR="${OUTPUT_DIR:-Новая папка}"
PREVIEW_DIR="${PREVIEW_DIR:-${OUTPUT_DIR}/previews}"
# END REGION AI

mkdir -p "$CHECK_DIR"
mkdir -p "$OUTPUT_DIR" "$PREVIEW_DIR"
rm -f "$LOW_UNIQUENESS_FLAG"

DEBUG=0
MUSIC_VARIANT=0
PROFILE=""
QT_META=1
STRICT_CLEAN=0
QUALITY="std"
AUTO_CLEAN=0
ENABLE_MIRROR=${ENABLE_MIRROR:-0}
ENABLE_INTRO=${ENABLE_INTRO:-0}
ENABLE_LUT=${ENABLE_LUT:-0}
DEVICE_INFO=1
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      ;;
    --music-variant)
      MUSIC_VARIANT=1
      ;;
    --profile)
      [ "${2:-}" ] || { echo "❌ --profile требует значение"; exit 1; }
      PROFILE=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    --qt-meta)
      QT_META=1
      ;;
    --no-qt-meta)
      QT_META=0
      ;;
    --strict-clean)
      STRICT_CLEAN=1
      QT_META=0
      ;;
    --quality)
      [ "${2:-}" ] || { echo "❌ --quality требует значение"; exit 1; }
      QUALITY=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
      case "$QUALITY" in
        high|std)
          ;;
        *)
          echo "❌ Неизвестное качество: $2"
          exit 1
          ;;
      esac
      shift
      ;;
    --auto-clean)
      AUTO_CLEAN=1
      ;;
    --mirror)
      ENABLE_MIRROR=1
      ;;
    --intro)
      ENABLE_INTRO=1
      ;;
    --lut)
      ENABLE_LUT=1
      ;;
    --no-device-info)
      DEVICE_INFO=0
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done
set -- "${POSITIONAL[@]}"

# REGION AI: runtime fallback defaults
: "${TARGET_DURATION:=0}"
: "${STRETCH_FACTOR:=1.0}"
: "${TEMPO_FACTOR:=1.0}"
: "${CLIP_START:=0}"
: "${CLIP_DURATION:=0}"
: "${SEED_HEX:=}"
: "${SEED:=}"
: "${AFILTER_CORE:=}"
: "${AFILTER:=anull}"
: "${PREVIEW_SS:=00:00:01.000}"
# END REGION AI

PREVIEW_SS_FALLBACK="00:00:01.000"
# Нормализованное значение времени превью вычисляется позже через normalize_ss_value
PREVIEW_SS_NORMALIZED=""

if [ "$STRICT_CLEAN" -eq 1 ]; then
  QT_META=0
fi

# REGION AI: output manifest configuration
MANIFEST="manifest.csv"
MANIFEST_PATH="${OUTPUT_DIR}/${MANIFEST}"
# END REGION AI
TARGET_W=1080
TARGET_H=1920
AUDIO_BR="128k"
BR_MIN=2800
BR_MAX=5000
FPS_BASE=(24 25 30 50 59.94 60)
FPS_RARE=(23.976 27 29.97 48 53.95 57)
AUDIO_SR=44100
PROFILE_FORCE_FPS=""
PROFILE_MAX_DURATION=0
VIDEO_PROFILE="high"
VIDEO_LEVEL="4.0"

case "$PROFILE" in
  tiktok)
    TARGET_W=1080
    TARGET_H=1920
    BR_MIN=3500
    BR_MAX=4200
    FPS_BASE=(30 60)
    FPS_RARE=()
    AUDIO_SR=44100
    PROFILE_FORCE_FPS=""
    PROFILE_MAX_DURATION=60
    VIDEO_PROFILE="high"
    VIDEO_LEVEL="4.0"
    ;;
  instagram)
    TARGET_W=1080
    TARGET_H=1350
    BR_MIN=3000
    BR_MAX=3600
    FPS_BASE=(30)
    FPS_RARE=()
    AUDIO_SR=48000
    PROFILE_MAX_DURATION=60
    VIDEO_PROFILE="high"
    VIDEO_LEVEL="4.1"
    ;;
  youtube)
    TARGET_W=1920
    TARGET_H=1080
    BR_MIN=5000
    BR_MAX=6500
    FPS_BASE=(24 30 60)
    FPS_RARE=()
    AUDIO_SR=48000
    VIDEO_PROFILE="high"
    VIDEO_LEVEL="4.2"
    ;;
  "" )
    ;;
  *)
    echo "❌ Неизвестный профиль: $PROFILE"
    exit 1
    ;;
esac
PROFILE_VALUE="${PROFILE:-default}"
NOISE_PROB_PERCENT=30
CROP_MAX_PX=6
AUDIO_TWEAK_PROB_PERCENT=50
MUSIC_VARIANT_TRACKS=()
MUSIC_VARIANT_TRACK=""
INTRO_CLIPS=()
LUT_FILES=()

case "$QUALITY" in
  high)
    CRF=18
    BR_MIN=4500
    BR_MAX=5500
    ;;
  std|*)
QUALITY="std"
CRF=22
    BR_MIN=3000
    BR_MAX=4000
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Требуется $1"; exit 1; }; }
need ffmpeg
need ffprobe
need exiftool

usage() { echo "Usage: $0 <input_video> [count]"; exit 1; }
[ "${1:-}" ] || usage
SRC="$1"
[ -f "$SRC" ] || { echo "❌ Нет файла: $SRC"; exit 1; }
COUNT="${2:-1}"
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "❌ count должен быть числом"; exit 1; }

mkdir -p "$OUTPUT_DIR"

cleanup_temp_artifacts() {
  local removed=0
  local -a patterns=("*.tmp" "*.log" "*.txt" "*.info" "*.wav" "*.m4a" "*.aac" "*.mp3" "*.mov" "*.MOV")
  local dir pattern file

  for dir in "." "$OUTPUT_DIR"; do
    [ -d "$dir" ] || continue
    for pattern in "${patterns[@]}"; do
      while IFS= read -r -d '' file; do
        if [ "$dir" = "$OUTPUT_DIR" ] && [[ "$file" == *.mp4 ]]; then
          continue
        fi
        if rm -f "$file" 2>/dev/null; then
          removed=$((removed + 1))
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print0)
    done
  done

  for dir in "logs" "$OUTPUT_DIR/logs"; do
    if [ -d "$dir" ]; then
      if rm -rf "$dir" 2>/dev/null; then
        removed=$((removed + 1))
      fi
    fi
  done

  if [ "$removed" -gt 0 ]; then
    echo "🧹 Auto-clean удалил временные файлы: $removed"
  fi
}


MANIFEST_HEADER="filename,bitrate,fps,duration,size_kb,encoder,software,creation_time,seed,target_duration,target_bitrate,validated,regen,profile,qt_make,qt_model,qt_software,ssim,phash_delta,quality_pass,quality,creative_mirror,creative_intro,creative_lut,preview"

MANIFEST_HEADER="filename,bitrate,fps,duration,size_kb,encoder,software,creation_time,seed,target_duration,target_bitrate,validated,regen,profile,qt_make,qt_model,ssim,psnr,phash,quality_pass,quality"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "$MANIFEST_HEADER" > "$MANIFEST_PATH"
else
  if ! head -n1 "$MANIFEST_PATH" | grep -q "target_duration"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},target_duration,target_bitrate,validated,regen"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены колонки target_duration и target_bitrate"
    echo "ℹ️ manifest обновлён: добавлены колонки validated и regen"
  elif ! head -n1 "$MANIFEST_PATH" | grep -q ",validated"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},validated,regen"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},," 
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены колонки validated и regen"
  fi
  if ! head -n1 "$MANIFEST_PATH" | grep -q ",profile"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},profile"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлена колонка profile"
  fi
  if ! head -n1 "$MANIFEST_PATH" | grep -q ",qt_make"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},qt_make,qt_model,qt_software"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены колонки qt_make, qt_model и qt_software"
  fi
  header_line=$(head -n1 "$MANIFEST_PATH")
  if printf '%s' "$header_line" | grep -q "phash_delta"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r old_header
      echo "${old_header//ssim,phash_delta,quality_pass,quality/ssim,psnr,phash,quality_pass,quality}"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        printf '%s\n' "$data_line" | awk -F',' 'BEGIN{OFS=","}{
          if (NF < 20) {print $0; next}
          out=""
          for(i=1;i<=16;i++){
            if(out=="") out=$i; else out=out OFS $i;
          }
          ssim=$17; phash=$18; qpass=$19; quality=$20;
          out=out OFS ssim OFS "" OFS phash OFS qpass OFS quality;
          print out;
        }'
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: колонки ssim, psnr и phash приведены к новому формату"
  fi
  header_line=$(head -n1 "$MANIFEST_PATH")
  if ! printf '%s' "$header_line" | grep -q ",psnr,"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},ssim,psnr,phash,quality_pass"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены колонки ssim, psnr, phash и quality_pass"
  elif ! printf '%s' "$header_line" | grep -q ",phash,"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},phash"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлена колонка phash"
  fi
  header_line=$(head -n1 "$MANIFEST_PATH")
  if ! printf '%s' "$header_line" | grep -q ",quality$"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},quality"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлена колонка quality"
  fi
  if ! head -n1 "$MANIFEST_PATH" | grep -q ",creative_mirror"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},creative_mirror,creative_intro,creative_lut,preview"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены creative-колонки и preview"
  fi
fi

# helpers
deterministic_md5() {
  if command -v md5 >/dev/null 2>&1; then
    printf "%s" "$1" | md5 | tr -d ' \t\n' | tail -c 32
  else
    printf "%s" "$1" | md5sum | awk '{print $1}'
  fi
}

RNG_HEX=""
RNG_POS=0
CURRENT_COPY_INDEX=0

init_rng() {
  RNG_HEX="$1"
  RNG_POS=0
}

rng_next_chunk() {
  if [ ${#RNG_HEX} -lt 4 ] || [ $((RNG_POS + 4)) -gt ${#RNG_HEX} ]; then
    RNG_HEX="$(deterministic_md5 "${RNG_HEX}_${RNG_POS}")"
    RNG_POS=0
  fi
  local chunk="${RNG_HEX:$RNG_POS:4}"
  RNG_POS=$((RNG_POS + 4))
  printf "%d" $((16#$chunk))
}

rand_int() {
  if [ $# -lt 2 ]; then
    printf "rand_int requires two arguments\n" >&2
    return 1
  fi

  local A="$1"
  local B="$2"
  local span raw

  span=$((B - A + 1))
  raw=$(rng_next_chunk)
  echo $((A + raw % span))
}

rand_choice() {
  local arrname=$1[@]
  local arr=("${!arrname}")
  local idx=$(( $(rng_next_chunk) % ${#arr[@]} ))
  echo "${arr[$idx]}"
}

rand_float() {
  local MIN="$1" MAX="$2" SCALE="$3"
  local raw=$(rng_next_chunk)
  awk -v min="$MIN" -v max="$MAX" -v r="$raw" -v scale="$SCALE" 'BEGIN {s=r/65535; printf "%.*f", scale, min + s*(max-min)}'
}

rand_uint32() {
  local hi=$(rng_next_chunk)
  local lo=$(rng_next_chunk)
  echo $(( (hi << 16) | lo ))
}

escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/\\\\'/g"
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
  local sanitized candidate final token_count=0

  sanitized=$(printf '%s' "$raw" | tr -s '[:space:]' ' ')
  sanitized=${sanitized# }
  sanitized=${sanitized% }

# REGION AI: tokenize ss candidate safely
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
# END REGION AI

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

# REGION AI: duration normalization helper
normalize_duration_value() {
  local raw="$1"
  local fallback="$2"
  local label="$3"
  local context="$4"
  local sanitized candidate final token_count=0
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
# END REGION AI

PREVIEW_SS_NORMALIZED=$(normalize_ss_value "$PREVIEW_SS" "$PREVIEW_SS_FALLBACK" "preview_ss" "init")
if [ -z "$PREVIEW_SS_NORMALIZED" ]; then
  PREVIEW_SS_NORMALIZED="$PREVIEW_SS_FALLBACK"
fi

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
    seconds=$(( -seconds ))
  fi
  local epoch
  epoch=$(iso_to_epoch "$iso")
  epoch=$((epoch + seconds))
  epoch_to_iso "$epoch"
}

file_size_bytes() {
  local size
  if size=$(stat -c %s "$1" 2>/dev/null); then
    echo "$size"
  else
    stat -f %z "$1"
  fi
}

date_supports_d_flag() {
  date -u -d "1970-01-01" >/dev/null 2>&1
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

date_supports_v_flag() {
  date -v-1d +%Y >/dev/null 2>&1
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

prepare_output_name() {
  while :; do
    local days hours minutes seconds stamp salt hash_val seed_hash
    days=$(rand_int 3 10)
    hours=$(rand_int 0 23)
    minutes=$(rand_int 0 59)
    seconds=$(rand_int 0 59)
    stamp=$(format_past_timestamp "%Y%m%d_%H%M%S" "$days" "$hours" "$minutes" "$seconds")
    if [ -z "$stamp" ]; then
      stamp=$(date -u +"%Y%m%d_%H%M%S")
    fi
    salt=$(date +%s%N 2>/dev/null || date +%s)
    hash_val=$(deterministic_md5 "${name}-${CURRENT_COPY_INDEX}-${salt}-${stamp}-${SEED_HEX}")
    seed_hash=${hash_val:0:5}
    OUT_NAME="VID_${stamp}_${seed_hash}.mp4"
    OUT="${OUTPUT_DIR}/${OUT_NAME}"
    [ -e "$OUT" ] || break
  done
  FILE_STEM="${OUT_NAME%.*}"
  FILE_EXT="${OUT_NAME##*.}"
}

touch_randomize_mtime() {
  local target="$1"
  [ -f "$target" ] || return
  local days hours minutes seconds touch_stamp
  days=$(rand_int 2 9)
  hours=$(rand_int 0 23)
  minutes=$(rand_int 0 59)
  seconds=$(rand_int 0 59)
  touch_stamp=$(format_past_timestamp "%Y%m%d%H%M.%S" "$days" "$hours" "$minutes" "$seconds")
  if [ -n "$touch_stamp" ]; then
    touch -t "$touch_stamp" "$target" 2>/dev/null || true
  fi
}

rand_description() {
  local choices=(
    "Edited on mobile"
    "Final export"
    "Captured on phone"
    "Shot in portrait"
    "Quick highlight"
  )
  local idx=$(( $(rng_next_chunk) % ${#choices[@]} ))
  echo "${choices[$idx]}"
}

pick_qt_combo() {
  local profile="$1"
  local -a combos
  case "$profile" in
    tiktok)
      combos=(
        "Apple|iPhone 13 Pro|iPhone14,2"
        "Apple|iPhone 12|iPhone13,2"
        "Apple|iPhone 13 mini|iPhone14,4"
        "Samsung|Galaxy S21|SM-G991B"
      )
      ;;
    instagram)
      combos=(
        "Apple|iPhone 12 Pro|iPhone13,3"
        "Apple|iPhone 14|iPhone15,2"
        "Google|Pixel 6|Pixel 6"
        "Sony|Xperia 5 III|XQ-BQ72"
      )
      ;;
    telegram)
      combos=(
        "Apple|iPhone 12 mini|iPhone13,1"
        "Samsung|Galaxy S22|SM-S901B"
        "Google|Pixel 7|GVU6C"
        "OnePlus|9 Pro|LE2123"
      )
      ;;
    *)
      combos=(
        "Apple|iPhone 13 Pro|iPhone14,2"
        "Apple|iPhone 12|iPhone13,2"
        "Apple|iPhone 12 mini|iPhone13,1"
        "Apple|iPhone 14|iPhone15,2"
        "Samsung|Galaxy S21|SM-G991B"
        "Samsung|Galaxy S22|SM-S901B"
        "Google|Pixel 6|Pixel 6"
        "Google|Pixel 7|GVU6C"
        "OnePlus|9 Pro|LE2123"
        "Sony|Xperia 5 III|XQ-BQ72"
        "Nothing|Phone (1)|A063"
      )
      ;;
  esac
  local idx=$(( $(rng_next_chunk) % ${#combos[@]} ))
  echo "${combos[$idx]}"
}

select_fps() {
  if [ -n "$PROFILE_FORCE_FPS" ]; then
    echo "$PROFILE_FORCE_FPS"
    return
  fi
  local use_rare=0
  if [ ${#FPS_RARE[@]} -gt 0 ] && [ "$(rand_int 1 100)" -le 22 ]; then
    use_rare=1
  fi
  if [ "$use_rare" -eq 1 ]; then
    rand_choice FPS_RARE
  else
    rand_choice FPS_BASE
  fi
}

compute_duration_profile() {
  local delta=$(rand_float 0.10 0.35 3)
  local sign=1
  if [ "$(rand_int 0 1)" -eq 0 ]; then
    sign=-1
  fi
read TARGET_DURATION STRETCH_FACTOR TEMPO_FACTOR <<EOF
$(awk -v orig="$ORIG_DURATION" -v delta="$delta" -v sign="$sign" 'BEGIN {
  orig+=0; delta+=0; sign+=0;
  target=orig + sign*delta;
  if (target < 0.2) {
    target=orig + delta;
  }
  if (target < 0.2) target=0.2;
  stretch=1.0; tempo=1.0;
  if (orig > 0.0) {
    stretch=target/orig;
    if (stretch == 0) stretch=1.0;
    tempo=(stretch != 0) ? 1.0/stretch : 1.0;
  }
  printf "%.3f %.6f %.6f", target, stretch, tempo;
}')
EOF
}

compute_clip_window() {
  local base_target="$1"
  local start_cap
  start_cap=$(awk -v orig="$ORIG_DURATION" 'BEGIN{orig+=0; cap=orig*0.08; if(cap>0.35) cap=0.35; if(cap<0.0) cap=0.0; print cap}')
  local shift="0.000"
  if awk -v cap="$start_cap" 'BEGIN{exit (cap>0.05?0:1)}'; then
    shift=$(rand_float 0.00 "$start_cap" 3)
  fi
  local dur_delta=$(rand_float 0.10 0.35 3)
  local dur_sign=$(rand_int 0 1)
  read CLIP_START CLIP_DURATION STRETCH_FACTOR TEMPO_FACTOR <<EOF
$(awk -v orig="$ORIG_DURATION" -v base="$base_target" -v shift="$shift" -v delta="$dur_delta" -v sign="$dur_sign" 'BEGIN {
  orig+=0; base+=0; shift+=0; delta+=0;
  start=shift;
  if (orig <= 0.6) {
    start=0.0;
  }
  avail=orig - start;
  if (avail < 0.6) {
    start=0.0;
    avail=orig;
  }
  target=base;
  if (sign == 0) {
    target=base - delta;
  } else {
    target=base + delta;
  }
  if (target < 0.30) {
    target=0.30;
  }
  if (target >= avail) {
    target=avail - 0.05;
    if (target < 0.30) {
      target=(avail > 0.35) ? avail - 0.02 : avail;
    }
  }
  if (target <= 0.0) {
    target=(avail > 0.35) ? avail - 0.02 : 0.30;
  }
  if (target <= 0.0) {
    target=0.30;
  }
  stretch=1.0;
  tempo=1.0;
  if (avail > 0.0 && target > 0.0) {
    stretch=target/avail;
    if (stretch == 0) {
      stretch=1.0;
    }
    tempo=(stretch != 0) ? 1.0/stretch : 1.0;
  }
  printf "%.3f %.3f %.6f %.6f", start, target, stretch, tempo;
}')
EOF
}

pick_crop_offsets() {
  CROP_W=$(rand_int 0 "$CROP_MAX_PX")
  CROP_H=$(rand_int 0 "$CROP_MAX_PX")
  CROP_X=0; CROP_Y=0
  if [ "$CROP_W" -gt 0 ]; then CROP_X=$(rand_int 0 "$CROP_W"); fi
  if [ "$CROP_H" -gt 0 ]; then CROP_Y=$(rand_int 0 "$CROP_H"); fi
}

pick_audio_chain() {
  local roll=$(rand_int 1 100)
  AUDIO_PROFILE="resample"
  local filters=("aresample=${AUDIO_SR}")
  if [ "$roll" -le "$AUDIO_TWEAK_PROB_PERCENT" ]; then
    AUDIO_PROFILE="asetrate"
    local factor=$(rand_float 0.985 1.015 6)
    filters=("asetrate=${AUDIO_SR}*${factor}" "aresample=${AUDIO_SR}")
  elif [ "$roll" -ge 85 ]; then
    AUDIO_PROFILE="anull"
    filters=("anull" "aresample=${AUDIO_SR}")
  fi
  local tempo_target="$TEMPO_FACTOR"
  if [ "$MUSIC_VARIANT" -eq 1 ]; then
    local tempo_sign=$(rand_int 0 1)
    local tempo_delta=$(rand_float 0.020 0.030 3)
    tempo_target=$(awk -v base="$TEMPO_FACTOR" -v sign="$tempo_sign" -v delta="$tempo_delta" '
BEGIN {
  base+=0; delta+=0;
  if (sign == 0) {
    printf "%.6f", base * (1.0 - delta);
  } else {
    printf "%.6f", base * (1.0 + delta);
  }
}
')
    AUDIO_PROFILE="${AUDIO_PROFILE}+tempo"
  fi
  filters+=("atempo=${tempo_target}")
  AFILTER_CORE=$(IFS=,; echo "${filters[*]}")
}

collect_music_variants() {
  MUSIC_VARIANT_TRACKS=()
  local src_dir="$(cd "$(dirname "$SRC")" && pwd)"
  local search_dirs=("${src_dir}/music_variants" "$src_dir")
  if [ -d "${PWD}/music_variants" ]; then
    search_dirs+=("${PWD}/music_variants")
  fi
  for dir in "${search_dirs[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' track; do
      MUSIC_VARIANT_TRACKS+=("$track")
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' \) -print0)
  done
}

collect_intro_clips() {
  INTRO_CLIPS=()
  local src_dir="$(cd "$(dirname "$SRC")" && pwd)"
  local search_dirs=()
  if [ -d "${src_dir}/intros" ]; then
    search_dirs+=("${src_dir}/intros")
  fi
  if [ -d "${PWD}/intros" ]; then
    search_dirs+=("${PWD}/intros")
  fi
  for dir in "${search_dirs[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' clip; do
      INTRO_CLIPS+=("$clip")
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' \) -print0)
  done
}

collect_lut_files() {
  LUT_FILES=()
  local src_dir="$(cd "$(dirname "$SRC")" && pwd)"
  local search_dirs=()
  if [ -d "${src_dir}/luts" ]; then
    search_dirs+=("${src_dir}/luts")
  fi
  if [ -d "${PWD}/luts" ]; then
    search_dirs+=("${PWD}/luts")
  fi
  for dir in "${search_dirs[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' lut; do
      LUT_FILES+=("$lut")
    done < <(find "$dir" -maxdepth 1 -type f -iname '*.cube' -print0)
  done
}

pick_music_variant_track() {
  MUSIC_VARIANT_TRACK=""
  local total=${#MUSIC_VARIANT_TRACKS[@]}
  if [ "$total" -gt 0 ]; then
    local idx=$(( $(rng_next_chunk) % total ))
    MUSIC_VARIANT_TRACK="${MUSIC_VARIANT_TRACKS[$idx]}"
  fi
}

base="$(basename "$SRC")"
name="${base%.*}"

ORIG_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SRC")
if [ -z "$ORIG_DURATION" ] || [ "$ORIG_DURATION" = "N/A" ]; then
  echo "❌ Не удалось получить длительность входного видео"
  exit 1
fi

if [ "$MUSIC_VARIANT" -eq 1 ]; then
  collect_music_variants
fi

if [ "$ENABLE_INTRO" -eq 1 ]; then
  collect_intro_clips
  if [ ${#INTRO_CLIPS[@]} -eq 0 ]; then
    echo "⚠️ Включено интро, но клипы не найдены (ожидается папка intros/)"
    ENABLE_INTRO=0
  fi
fi

if [ "$ENABLE_LUT" -eq 1 ]; then
  collect_lut_files
fi

COMBO_HISTORY=""
declare -a LAST_COMBOS=()
declare -a RUN_FILES=()
declare -a RUN_BITRATES=()
declare -a RUN_FPS=()
declare -a RUN_DURATIONS=()
declare -a RUN_SIZES=()
declare -a RUN_ENCODERS=()
declare -a RUN_SOFTWARES=()
declare -a RUN_CREATION_TIMES=()
declare -a RUN_SEEDS=()
declare -a RUN_TARGET_DURS=()
declare -a RUN_TARGET_BRS=()
declare -a RUN_COMBOS=()
declare -a RUN_PROFILES=()
declare -a RUN_QUALITIES=()
declare -a RUN_QT_MAKES=()
declare -a RUN_QT_MODELS=()
declare -a RUN_QT_SOFTWARES=()
declare -a RUN_SSIM=()
declare -a RUN_PSNR=()
declare -a RUN_PHASH=()
declare -a RUN_QPASS=()
declare -a RUN_CREATIVE_MIRROR=()
declare -a RUN_CREATIVE_INTRO=()
declare -a RUN_CREATIVE_LUT=()
declare -a RUN_PREVIEWS=()
declare -a QUALITY_ISSUES=()
declare -a QUALITY_COPY_IDS=()
USED_SOFT_ENC_KEYS_LIST=""

combo_key_seen() {
  local key="$1" existing
  if [ -z "${USED_SOFT_ENC_KEYS_LIST:-}" ]; then
    return 1
  fi
  while IFS= read -r existing; do
    [ -z "$existing" ] && continue
    if [ "$existing" = "$key" ]; then
      return 0
    fi
  done <<EOF
${USED_SOFT_ENC_KEYS_LIST}
EOF
  return 1
}

mark_combo_key() {
  local key="$1"
  : "${USED_SOFT_ENC_KEYS_LIST:=}"
  if combo_key_seen "$key"; then
    return
  fi
  if [ -z "$USED_SOFT_ENC_KEYS_LIST" ]; then
    USED_SOFT_ENC_KEYS_LIST="$key"
  else
    USED_SOFT_ENC_KEYS_LIST="${USED_SOFT_ENC_KEYS_LIST}"$'\n'"$key"
  fi
}

unmark_combo_key() {
  local key="$1" existing new_list=""
  if [ -z "${USED_SOFT_ENC_KEYS_LIST:-}" ]; then
    echo "⚠️ Нет сохранённых soft encoder ключей для удаления ($key)"
    return
  fi
  while IFS= read -r existing; do
    [ -z "$existing" ] && continue
    if [ "$existing" != "$key" ]; then
      if [ -z "$new_list" ]; then
        new_list="$existing"
      else
        new_list="${new_list}"$'\n'"$existing"
      fi
    fi
  done <<EOF
${USED_SOFT_ENC_KEYS_LIST}
EOF
  USED_SOFT_ENC_KEYS_LIST="$new_list"
}

pick_software_encoder() {
  local profile_key="${1:-default}" seed="$2" attempt=0 digest=""
  local -a names majors
  case "$profile_key" in
    tiktok) names=("CapCut" "VN") majors=(12 2) ;;
    instagram) names=("Premiere Rush" "iMovie") majors=(1 10) ;;
    telegram) names=("ShotCut" "FFmpeg") majors=(3 5) ;;
    *) names=("CapCut" "VN" "Premiere Rush" "iMovie" "ShotCut" "FFmpeg") majors=(12 2 1 10 3 5) ;;
  esac
  while :; do
    digest=$(deterministic_md5 "${seed}_${profile_key}_soft_${attempt}")
    local idx=$((16#${digest:0:2} % ${#names[@]}))
    local minor=$((1 + 16#${digest:2:2} % 9))
    local enc_minor=$((2 + 16#${digest:4:2} % 58))
    SOFTWARE_TAG="${names[$idx]} ${majors[$idx]}.${minor}"
    ENCODER_TAG=$(printf "Lavf62.%d.100" "$enc_minor")
    local combo_key="${SOFTWARE_TAG}|${ENCODER_TAG}"
    if ! combo_key_seen "$combo_key"; then
      mark_combo_key "$combo_key"
      break
    fi
    attempt=$((attempt + 1))
  done
}

REGEN_ITER=0
REGEN_OCCURRED=0
LOW_UNIQUENESS_TRIGGERED=0
MAX_REGEN_ATTEMPTS=2

duration_bucket() {
  local value="$1"
  awk -v v="$value" 'BEGIN { printf "%.1f", v }'
}

duplicate_threshold() {
  local total="$1"
  if [ "$total" -ge 10 ]; then
    echo 4
  elif [ "$total" -ge 6 ]; then
    echo 3
  else
    echo 2
  fi
}

calculate_duplicate_max() {
  local fps_arr_name="$1"
  local br_arr_name="$2"
  local dur_arr_name="$3"
  local -a seen_keys=()
  local -a seen_counts=()
  local max_count=0
  local total=0
  eval "total=\${#$fps_arr_name[@]}"
  local idx=0
  while [ "$idx" -lt "$total" ]; do
    local fps_val br_val dur_val key
    eval "fps_val=\${$fps_arr_name[$idx]}"
    eval "br_val=\${$br_arr_name[$idx]}"
    eval "dur_val=\${$dur_arr_name[$idx]}"
    key="${fps_val}|${br_val}|$(duration_bucket "$dur_val")"
    local found=0
    local current=0
    local list_idx=0
    while [ "$list_idx" -lt "${#seen_keys[@]}" ]; do
      if [ "${seen_keys[$list_idx]}" = "$key" ]; then
        current=$(( ${seen_counts[$list_idx]} + 1 ))
        seen_counts[$list_idx]=$current
        found=1
        break
      fi
      list_idx=$((list_idx + 1))
    done
    if [ "$found" -eq 0 ]; then
      seen_keys+=("$key")
      current=1
      seen_counts+=("$current")
    fi
    if [ "$current" -gt "$max_count" ]; then
      max_count=$current
    fi
    idx=$((idx + 1))
  done
  echo "$max_count"
}

remove_last_generated() {
  local remove_count="$1"
  for ((drop=0; drop<remove_count; drop++)); do
    local idx=$(( ${#RUN_FILES[@]} - 1 ))
    [ "$idx" -lt 0 ] && break
    local combo_key="${RUN_SOFTWARES[$idx]}|${RUN_ENCODERS[$idx]}"
    unmark_combo_key "$combo_key"
    local file_path="${OUTPUT_DIR}/${RUN_FILES[$idx]}"
    local preview_file="${RUN_PREVIEWS[$idx]:-}"
    rm -f "$file_path" 2>/dev/null || true
    if [ -n "$preview_file" ]; then
      rm -f "${OUTPUT_DIR}/${preview_file}" 2>/dev/null || true
    fi
    RUN_FILES=("${RUN_FILES[@]:0:$idx}")
    RUN_BITRATES=("${RUN_BITRATES[@]:0:$idx}")
    RUN_FPS=("${RUN_FPS[@]:0:$idx}")
    RUN_DURATIONS=("${RUN_DURATIONS[@]:0:$idx}")
    RUN_SIZES=("${RUN_SIZES[@]:0:$idx}")
    RUN_ENCODERS=("${RUN_ENCODERS[@]:0:$idx}")
    RUN_SOFTWARES=("${RUN_SOFTWARES[@]:0:$idx}")
    RUN_CREATION_TIMES=("${RUN_CREATION_TIMES[@]:0:$idx}")
    RUN_SEEDS=("${RUN_SEEDS[@]:0:$idx}")
    RUN_TARGET_DURS=("${RUN_TARGET_DURS[@]:0:$idx}")
    RUN_TARGET_BRS=("${RUN_TARGET_BRS[@]:0:$idx}")
    RUN_COMBOS=("${RUN_COMBOS[@]:0:$idx}")
    RUN_PROFILES=("${RUN_PROFILES[@]:0:$idx}")
    RUN_QUALITIES=("${RUN_QUALITIES[@]:0:$idx}")
    RUN_QT_MAKES=("${RUN_QT_MAKES[@]:0:$idx}")
    RUN_QT_MODELS=("${RUN_QT_MODELS[@]:0:$idx}")
    RUN_QT_SOFTWARES=("${RUN_QT_SOFTWARES[@]:0:$idx}")
    RUN_SSIM=("${RUN_SSIM[@]:0:$idx}")
    RUN_PSNR=("${RUN_PSNR[@]:0:$idx}")
    RUN_PHASH=("${RUN_PHASH[@]:0:$idx}")
    RUN_QPASS=("${RUN_QPASS[@]:0:$idx}")
    RUN_CREATIVE_MIRROR=("${RUN_CREATIVE_MIRROR[@]:0:$idx}")
    RUN_CREATIVE_INTRO=("${RUN_CREATIVE_INTRO[@]:0:$idx}")
    RUN_CREATIVE_LUT=("${RUN_CREATIVE_LUT[@]:0:$idx}")
    RUN_PREVIEWS=("${RUN_PREVIEWS[@]:0:$idx}")
    if [ ${#LAST_COMBOS[@]} -gt 0 ]; then
      LAST_COMBOS=("${LAST_COMBOS[@]:0:${#LAST_COMBOS[@]}-1}")
    fi
  done
}

remove_indices_for_regen() {
  local indices=("$@")
  [ "${#indices[@]}" -eq 0 ] && return
  local sorted
  sorted=$(printf '%s\n' "${indices[@]}" | sort -rn)
  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    [ "$idx" -lt 0 ] && continue
    if [ "$idx" -ge "${#RUN_FILES[@]}" ]; then
      continue
    fi
    local combo_key="${RUN_SOFTWARES[$idx]}|${RUN_ENCODERS[$idx]}"
    unmark_combo_key "$combo_key"
    rm -f "${OUTPUT_DIR}/${RUN_FILES[$idx]}" 2>/dev/null || true
    if [ -n "${RUN_PREVIEWS[$idx]:-}" ]; then
      rm -f "${OUTPUT_DIR}/${RUN_PREVIEWS[$idx]}" 2>/dev/null || true
    fi
    RUN_FILES=("${RUN_FILES[@]:0:$idx}" "${RUN_FILES[@]:$((idx + 1))}")
    RUN_BITRATES=("${RUN_BITRATES[@]:0:$idx}" "${RUN_BITRATES[@]:$((idx + 1))}")
    RUN_FPS=("${RUN_FPS[@]:0:$idx}" "${RUN_FPS[@]:$((idx + 1))}")
    RUN_DURATIONS=("${RUN_DURATIONS[@]:0:$idx}" "${RUN_DURATIONS[@]:$((idx + 1))}")
    RUN_SIZES=("${RUN_SIZES[@]:0:$idx}" "${RUN_SIZES[@]:$((idx + 1))}")
    RUN_ENCODERS=("${RUN_ENCODERS[@]:0:$idx}" "${RUN_ENCODERS[@]:$((idx + 1))}")
    RUN_SOFTWARES=("${RUN_SOFTWARES[@]:0:$idx}" "${RUN_SOFTWARES[@]:$((idx + 1))}")
    RUN_CREATION_TIMES=("${RUN_CREATION_TIMES[@]:0:$idx}" "${RUN_CREATION_TIMES[@]:$((idx + 1))}")
    RUN_SEEDS=("${RUN_SEEDS[@]:0:$idx}" "${RUN_SEEDS[@]:$((idx + 1))}")
    RUN_TARGET_DURS=("${RUN_TARGET_DURS[@]:0:$idx}" "${RUN_TARGET_DURS[@]:$((idx + 1))}")
    RUN_TARGET_BRS=("${RUN_TARGET_BRS[@]:0:$idx}" "${RUN_TARGET_BRS[@]:$((idx + 1))}")
    RUN_COMBOS=("${RUN_COMBOS[@]:0:$idx}" "${RUN_COMBOS[@]:$((idx + 1))}")
    RUN_PROFILES=("${RUN_PROFILES[@]:0:$idx}" "${RUN_PROFILES[@]:$((idx + 1))}")
    RUN_QUALITIES=("${RUN_QUALITIES[@]:0:$idx}" "${RUN_QUALITIES[@]:$((idx + 1))}")
    RUN_QT_MAKES=("${RUN_QT_MAKES[@]:0:$idx}" "${RUN_QT_MAKES[@]:$((idx + 1))}")
    RUN_QT_MODELS=("${RUN_QT_MODELS[@]:0:$idx}" "${RUN_QT_MODELS[@]:$((idx + 1))}")
    RUN_QT_SOFTWARES=("${RUN_QT_SOFTWARES[@]:0:$idx}" "${RUN_QT_SOFTWARES[@]:$((idx + 1))}")
    RUN_SSIM=("${RUN_SSIM[@]:0:$idx}" "${RUN_SSIM[@]:$((idx + 1))}")
    RUN_PSNR=("${RUN_PSNR[@]:0:$idx}" "${RUN_PSNR[@]:$((idx + 1))}")
    RUN_PHASH=("${RUN_PHASH[@]:0:$idx}" "${RUN_PHASH[@]:$((idx + 1))}")
    RUN_QPASS=("${RUN_QPASS[@]:0:$idx}" "${RUN_QPASS[@]:$((idx + 1))}")
    RUN_CREATIVE_MIRROR=("${RUN_CREATIVE_MIRROR[@]:0:$idx}" "${RUN_CREATIVE_MIRROR[@]:$((idx + 1))}")
    RUN_CREATIVE_INTRO=("${RUN_CREATIVE_INTRO[@]:0:$idx}" "${RUN_CREATIVE_INTRO[@]:$((idx + 1))}")
    RUN_CREATIVE_LUT=("${RUN_CREATIVE_LUT[@]:0:$idx}" "${RUN_CREATIVE_LUT[@]:$((idx + 1))}")
    RUN_PREVIEWS=("${RUN_PREVIEWS[@]:0:$idx}" "${RUN_PREVIEWS[@]:$((idx + 1))}")
  done <<<"$sorted"
  LAST_COMBOS=("${RUN_COMBOS[@]}")
}

compute_phash_diff() {
  local source_file="$1" compare_file="$2" value="NA"
  local py_path="$BASE_DIR"
  if [ -n "${PYTHONPATH:-}" ]; then
    py_path="${BASE_DIR}:${PYTHONPATH}"
  fi
  value=$(PYTHONPATH="$py_path" python3 - "$source_file" "$compare_file" <<'PY'
import pathlib
import sys

try:
    import phash_check
except Exception:  # noqa: BLE001
    print("NA")
    sys.exit(0)

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])

try:
    src_frame = phash_check._read_frame(src)
    dst_frame = phash_check._read_frame(dst)
    src_hash = phash_check._phash(src_frame)
    dst_hash = phash_check._phash(dst_frame)
    diff = phash_check._hamming(src_hash, dst_hash)
except Exception:  # noqa: BLE001
    print("NA")
else:
    print(diff)
PY
)
  printf '%s' "${value:-NA}"
}

compute_metrics_for_copy() {
  local source_file="$1" compare_file="$2"
  local ssim_log psnr_log ssim_val psnr_val phash_val
  ssim_log=$(ffmpeg -v error -i "$source_file" -i "$compare_file" -lavfi "ssim" -f null - 2>&1 || true)
  ssim_val=$(printf '%s\n' "$ssim_log" | awk -F'All:' '/All:/{gsub(/^[ \t]+/,"",$2); split($2,a," "); print a[1]; exit}')
  [ -n "$ssim_val" ] || ssim_val="0.000"
  psnr_log=$(ffmpeg -v error -i "$source_file" -i "$compare_file" -lavfi "psnr" -f null - 2>&1 || true)
  psnr_val=$(printf '%s\n' "$psnr_log" | awk -F'average:' '/average:/{gsub(/^[ \t]+/,"",$2); split($2,a," "); print a[1]; exit}')
  [ -n "$psnr_val" ] || psnr_val="0.00"
  case "$psnr_val" in
    inf|Inf|INF|nan|NaN|NA)
      psnr_val="99.99"
      ;;
  esac
  phash_val=$(compute_phash_diff "$source_file" "$compare_file")
  printf '%s|%s|%s' "$ssim_val" "$psnr_val" "$phash_val"
}

quality_check() {
  QUALITY_ISSUES=()
  QUALITY_COPY_IDS=()
  RUN_QPASS=()
  local idx
  for idx in "${!RUN_FILES[@]}"; do
    local copy_path="${OUTPUT_DIR}/${RUN_FILES[$idx]}"
    local ssim_val="${RUN_SSIM[$idx]:-}"
    local psnr_val="${RUN_PSNR[$idx]:-}"
    local phash_val="${RUN_PHASH[$idx]:-NA}"
    if [ -z "$ssim_val" ] || [ -z "$psnr_val" ] || [ "$psnr_val" = "NA" ]; then
      local metrics
      metrics=$(compute_metrics_for_copy "$SRC" "$copy_path")
      ssim_val=${metrics%%|*}
      local rest=${metrics#*|}
      psnr_val=${rest%%|*}
      phash_val=${rest#*|}
      RUN_SSIM[$idx]="$ssim_val"
      RUN_PSNR[$idx]="$psnr_val"
      RUN_PHASH[$idx]="$phash_val"
    fi
    local dur_delta
    dur_delta=$(awk -v o="$ORIG_DURATION" -v c="${RUN_DURATIONS[$idx]}" 'BEGIN{o+=0;c+=0;diff=o-c;if(diff<0) diff=-diff;printf "%.3f",diff}')
    local br_delta
    br_delta=$(awk -v t="${RUN_TARGET_BRS[$idx]}" -v b="${RUN_BITRATES[$idx]}" 'BEGIN{t+=0;b+=0;diff=t-b;if(diff<0) diff=-diff;printf "%.0f",diff}')
    local pass=true
    if ! awk -v s="$ssim_val" 'BEGIN{exit (s>=0.95?0:1)}'; then pass=false; fi
    if ! awk -v p="$psnr_val" 'BEGIN{exit (p>=34?0:1)}'; then pass=false; fi
    if ! awk -v d="$dur_delta" 'BEGIN{exit (d<=0.50?0:1)}'; then pass=false; fi
    if ! awk -v b="$br_delta" 'BEGIN{exit (b<=800?0:1)}'; then pass=false; fi
    if [ "$pass" = true ]; then
      RUN_QPASS+=("true")
    else
      RUN_QPASS+=("false")
      QUALITY_ISSUES+=("$idx")
      QUALITY_COPY_IDS+=("$((idx + 1))")
      echo "⚠️ Подозрительное качество ${RUN_FILES[$idx]} (ssim=$ssim_val psnr=$psnr_val phash=$phash_val Δdur=$dur_delta Δbr=$br_delta)"
    fi
  done
}

warn_similar_copies() {
  local total=${#RUN_FILES[@]}
  [ "$total" -lt 2 ] && return
  local i j pair_ssim pair_psnr pair_log psnr_log
  local -a warnings=()
  for ((i=0;i<total;i++)); do
    for ((j=i+1;j<total;j++)); do
      if [ "${RUN_FPS[$i]}" != "${RUN_FPS[$j]}" ]; then
        continue
      fi
      if [ "${RUN_BITRATES[$i]}" != "${RUN_BITRATES[$j]}" ]; then
        continue
      fi
      pair_log=$(ffmpeg -v error -i "${OUTPUT_DIR}/${RUN_FILES[$i]}" -i "${OUTPUT_DIR}/${RUN_FILES[$j]}" -lavfi "ssim" -f null - 2>&1 || true)
      pair_ssim=$(printf '%s\n' "$pair_log" | awk -F'All:' '/All:/{gsub(/^[ \t]+/,"",$2); split($2,a," "); print a[1]; exit}')
      [ -n "$pair_ssim" ] || pair_ssim="0.000"
      psnr_log=$(ffmpeg -v error -i "${OUTPUT_DIR}/${RUN_FILES[$i]}" -i "${OUTPUT_DIR}/${RUN_FILES[$j]}" -lavfi "psnr" -f null - 2>&1 || true)
      pair_psnr=$(printf '%s\n' "$psnr_log" | awk -F'average:' '/average:/{gsub(/^[ \t]+/,"",$2); split($2,a," "); print a[1]; exit}')
      [ -n "$pair_psnr" ] || pair_psnr="0.00"
      case "$pair_psnr" in
        inf|Inf|INF|nan|NaN|NA)
          pair_psnr="99.99"
          ;;
      esac
      if awk -v s="$pair_ssim" -v p="$pair_psnr" 'BEGIN{exit (s>=0.985 && p>=45?0:1)}'; then
        warnings+=("v$((i + 1)) и v$((j + 1)) (SSIM=$pair_ssim PSNR=$pair_psnr)")
      fi
    done
  done
  if [ "${#warnings[@]}" -gt 0 ]; then
    local message="⚠️ Копии "
    local idx
    for idx in "${!warnings[@]}"; do
      if [ "$idx" -gt 0 ]; then
        message+="; "
      fi
      message+="${warnings[$idx]}"
    done
    message+=" слишком похожи. Перегенерация рекомендована."
    echo "$message"
  fi
}

low_uniqueness_fallback() {
  local total=${#RUN_FILES[@]}
  if [ "$total" -lt 2 ]; then
    return 1
  fi

  local idx low_ssim=0 low_phash=0
  local -a candidates=()
  local -a seen_indices=()

  for idx in "${!RUN_FILES[@]}"; do
    local ssim_val="${RUN_SSIM[$idx]:-0}"
    local phash_val="${RUN_PHASH[$idx]:-0}"
    local flag=0
    local ssim_bad=0
    local phash_bad=0
    if awk -v s="$ssim_val" 'BEGIN{s+=0; exit (s<0.91?0:1)}'; then
      low_ssim=$((low_ssim + 1))
      flag=1
      ssim_bad=1
    fi
    if [ "$phash_val" != "NA" ] && [ -n "$phash_val" ]; then
      if awk -v p="$phash_val" 'BEGIN{p+=0; exit (p<5?0:1)}'; then
        low_phash=$((low_phash + 1))
        flag=1
        phash_bad=1
      fi
    fi
    if [ "$flag" -eq 1 ]; then
      local score
      score=$(awk -v s="$ssim_val" -v p="$phash_val" -v sb="$ssim_bad" -v pb="$phash_bad" 'BEGIN {
        s+=0; p+=0;
        bad_s = (sb>0 && s<0.91)?(0.91-s)*120:0;
        bad_p = (pb>0 && p<5)?(5-p)*12:0;
        printf "%07.3f", bad_s + bad_p;
      }')
      candidates+=("${score}|${idx}")
    fi
  done

  local trigger=1
  if ! awk -v low="$low_ssim" -v total="$total" 'BEGIN{exit (low*2>total?0:1)}'; then
    if ! awk -v low="$low_phash" -v total="$total" 'BEGIN{exit (low*2>total?0:1)}'; then
      trigger=0
    fi
  fi

  if [ "$trigger" -eq 0 ] || [ "${#candidates[@]}" -eq 0 ]; then
    return 1
  fi

  local regen_count=2
  if [ "$total" -ge 3 ]; then
    regen_count=$(rand_int 2 3)
  fi
  if [ "$regen_count" -gt "$total" ]; then
    regen_count="$total"
  fi

  local selection
  selection=$(printf '%s\n' "${candidates[@]}" | sort -r)
  local -a regen_indices=()
  while IFS='|' read -r _score raw_idx; do
    [ -z "$raw_idx" ] && continue
    regen_indices+=("$raw_idx")
    if [ "${#regen_indices[@]}" -ge "$regen_count" ]; then
      break
    fi
  done <<<"$selection"

  if [ "${#regen_indices[@]}" -eq 0 ]; then
    return 1
  fi

  echo "⚠️ Low uniqueness fallback triggered. Перегенерация копий: ${#regen_indices[@]}"
  LOW_UNIQUENESS_TRIGGERED=1
  REGEN_OCCURRED=1

  local -a copy_ids=()
  for idx in "${regen_indices[@]}"; do
    copy_ids+=("$((idx + 1))")
  done

  remove_indices_for_regen "${regen_indices[@]}"

  REGEN_ITER=$((REGEN_ITER + 1))
  local sorted_ids
  sorted_ids=$(printf '%s\n' "${copy_ids[@]}" | sort -n)
  while IFS= read -r cid; do
    [ -z "$cid" ] && continue
    generate_copy "$cid" "$REGEN_ITER"
  done <<<"$sorted_ids"

  return 0
}

report_template_statistics() {
  [ -f "$MANIFEST_PATH" ] || return
  local stats
  stats=$(awk -F',' 'NR>1 && NF>=4 {key=$3"|"$2"|"$4; count[key]++} END{for(k in count) if(count[k]>1) printf "%s %d\n",k,count[k];}' "$MANIFEST_PATH")
  if [ -z "$stats" ]; then
    echo "ℹ️ Совпадений шаблонов не обнаружено"
    return
  fi
  echo "ℹ️ Статистика совпадений manifest:"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local count="${line##* }"
    local combo="${line% $count}"
    local IFS='|'
    read -r fps_val br_val dur_val <<<"$combo"
    echo "ℹ️ Повтор: fps=$fps_val bitrate=$br_val duration=$dur_val — ${count} копий"
  done <<<"$stats"
}

generate_copy() {
  local copy_index="$1"
  local regen_tag="${2:-0}"
  local attempt=0
  while :; do
    SEED_HEX=$(deterministic_md5 "${SRC}_${copy_index}_соль_${regen_tag}_${attempt}")
    init_rng "$SEED_HEX"

    # параметры видео
    FPS=$(select_fps)

    BR=$(rand_int "$BR_MIN" "$BR_MAX")

    compute_duration_profile

    if [ -n "$PROFILE_MAX_DURATION" ] && [ "$PROFILE_MAX_DURATION" -gt 0 ]; then
      if [ "$(awk -v dur="$TARGET_DURATION" -v limit="$PROFILE_MAX_DURATION" 'BEGIN{print (dur>limit)?1:0}')" -eq 1 ]; then
        local original_duration="$TARGET_DURATION"
        TARGET_DURATION=$(awk -v limit="$PROFILE_MAX_DURATION" 'BEGIN{printf "%.3f", limit+0}')
        read STRETCH_FACTOR TEMPO_FACTOR <<EOF
$(awk -v orig="$ORIG_DURATION" -v limit="$PROFILE_MAX_DURATION" 'BEGIN {
  orig+=0;
  limit+=0;
  stretch=1.0;
  tempo=1.0;
  if (orig > 0.0) {
    stretch=limit/orig;
    if (stretch == 0) stretch=1.0;
    tempo=(stretch != 0) ? 1.0/stretch : 1.0;
  }
  printf "%.6f %.6f", stretch, tempo;
}')
EOF
        echo "⚠️ Профиль $PROFILE_VALUE ограничил длительность ${original_duration}s → ${TARGET_DURATION}s"
      fi
    fi

    local CLIP_START="0.000" CLIP_DURATION="$TARGET_DURATION"
    local clip_duration_fallback="$TARGET_DURATION"
    compute_clip_window "$TARGET_DURATION"
# REGION AI: sanitize clip window timings
    CLIP_DURATION=$(normalize_duration_value "$CLIP_DURATION" "$clip_duration_fallback" "clip_duration" "copy ${copy_index}")
    TARGET_DURATION="$CLIP_DURATION"
    CLIP_START=$(normalize_ss_value "$CLIP_START" "0.000" "clip_start" "copy ${copy_index}")
# END REGION AI

    NOISE=0
    if [ "$(rand_int 1 100)" -le "$NOISE_PROB_PERCENT" ]; then
      NOISE=1
    fi

    pick_crop_offsets

    pick_audio_chain

    local jitter_filters=()
    if (( RANDOM % 3 == 0 )); then
      jitter_filters=("asetrate=${AUDIO_SR}*1.$((RANDOM%6))" "aresample=${AUDIO_SR}")
      AUDIO_PROFILE="${AUDIO_PROFILE}+jitter"
    else
      jitter_filters=("anull")
    fi
    local jitter_chain="$(IFS=,; echo "${jitter_filters[*]}")"
    if [ "$jitter_chain" = "anull" ]; then
      AFILTER="$AFILTER_CORE"
    elif [ -n "${AFILTER_CORE:-}" ]; then
      AFILTER="${jitter_chain},${AFILTER_CORE}"
    else
      AFILTER="$jitter_chain"
    fi

    MUSIC_VARIANT_TRACK=""
    if [ "$MUSIC_VARIANT" -eq 1 ]; then
      pick_music_variant_track
      if [ -n "$MUSIC_VARIANT_TRACK" ]; then
        AUDIO_PROFILE="${AUDIO_PROFILE}+music"
      fi
    fi

    local MIRROR_DESC="none" MIRROR_FILTER="" MIRROR_ACTIVE=0
    if [ "$ENABLE_MIRROR" -eq 1 ]; then
      MIRROR_ACTIVE=1
      if [ "$(rand_int 0 1)" -eq 0 ]; then
        MIRROR_FILTER="hflip"
      else
        MIRROR_FILTER="vflip"
      fi
      MIRROR_DESC="$MIRROR_FILTER"
    fi

    local LUT_DESC="none" LUT_FILTER="" LUT_ACTIVE=0
    if [ "$ENABLE_LUT" -eq 1 ]; then
      LUT_ACTIVE=1
      if [ ${#LUT_FILES[@]} -gt 0 ]; then
        local lut_choice
        lut_choice=$(rand_choice LUT_FILES)
        LUT_DESC="$(basename "$lut_choice")"
        LUT_DESC="${LUT_DESC//,/ _}"
        LUT_FILTER="lut3d=file='$(escape_single_quotes "$lut_choice")':interp=tetrahedral"
      else
        LUT_DESC="curves_vintage"
        LUT_FILTER="curves=preset=vintage"
      fi
    fi

    local INTRO_ACTIVE=0 INTRO_SOURCE="" INTRO_DURATION="" INTRO_DESC="none"
    if [ "$ENABLE_INTRO" -eq 1 ] && [ ${#INTRO_CLIPS[@]} -gt 0 ]; then
      INTRO_ACTIVE=1
      INTRO_SOURCE=$(rand_choice INTRO_CLIPS)
      INTRO_DURATION=$(rand_float 1.0 2.0 2)
      INTRO_DESC="$(basename "$INTRO_SOURCE")"
      INTRO_DESC="${INTRO_DESC//,/ _}"
    fi

    combo_key="${FPS}|${BR}|${TARGET_DURATION}"

    duplicate=0
    case " $COMBO_HISTORY " in
      *" $combo_key "*) duplicate=1 ;;
    esac

    consec=0
    len=${#LAST_COMBOS[@]}
    if [ "$len" -gt 0 ]; then
      for ((idx=len-1; idx>=0 && idx>=len-3; idx--)); do
        if [ "${LAST_COMBOS[$idx]}" = "$combo_key" ]; then
          consec=$((consec + 1))
        else
          break
        fi
      done
    fi

    if [ "$duplicate" -eq 0 ] && [ "$consec" -lt 3 ]; then
      break
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -gt 12 ]; then
      echo "⚠️ Не удалось подобрать уникальные параметры для копии $copy_index, используем последние"
      break
    fi
  done

  SEED="$SEED_HEX"
  LAST_COMBOS+=("$combo_key")
  COMBO_HISTORY="${COMBO_HISTORY}${combo_key} "

  RATE_PAD=$(rand_int 250 650)
  MAXRATE=$((BR + RATE_PAD))
  BUFSIZE=$((BR * 2 + RATE_PAD * 2))

  pick_software_encoder "$PROFILE_VALUE" "$SEED_HEX"

  CREATION_TIME=$(generate_iso_timestamp)
  CREATION_TIME=$(jitter_iso_timestamp "$CREATION_TIME")
  CREATION_TIME_EXIF="$CREATION_TIME"
  CURRENT_COPY_INDEX="$copy_index"
  prepare_output_name
  local FINAL_OUT="$OUT"
  local ENCODE_TARGET="$FINAL_OUT"
  local INTRO_OUTPUT_PATH=""
  local CONCAT_LIST_FILE=""
  if [ "$INTRO_ACTIVE" -eq 1 ] && [ -n "$INTRO_SOURCE" ]; then
    ENCODE_TARGET=$(mktemp "${OUTPUT_DIR}/.intro_main_XXXXXX.${FILE_EXT}")
    INTRO_OUTPUT_PATH=$(mktemp "${OUTPUT_DIR}/.intro_clip_XXXXXX.${FILE_EXT}")
  fi
  TITLE="$FILE_STEM"
  DESCRIPTION="$(rand_description)"
  local QT_MAKE="" QT_MODEL="" QT_SOFTWARE="" DEVICE_MODEL_CODE=""
  if [ "$QT_META" -eq 1 ]; then
    local qt_choice=""
    case "$PROFILE_VALUE" in
      tiktok)
        qt_choice="Apple|iPhone 13 Pro|iPhone14,2"
        ;;
      instagram)
        qt_choice="Apple|iPhone 12 Pro|iPhone13,3"
        ;;
      telegram)
        qt_choice="Apple|iPhone 12 mini|iPhone13,1"
        ;;
      *)
        ;;
    esac
    if [ -z "$qt_choice" ] || [ "$(rand_int 0 1)" -eq 1 ]; then
      qt_choice=$(pick_qt_combo "$PROFILE_VALUE")
    fi
    if [ -n "$qt_choice" ]; then
      QT_MAKE="${qt_choice%%|*}"
      local rest="${qt_choice#*|}"
      QT_MODEL="${rest%%|*}"
      if [ "$rest" != "$QT_MODEL" ]; then
        DEVICE_MODEL_CODE="${rest#*|}"
      fi
    fi
    if [ -z "$DEVICE_MODEL_CODE" ] && [ -n "$QT_MODEL" ]; then
      case "$QT_MODEL" in
        "iPhone 13 Pro") DEVICE_MODEL_CODE="iPhone14,2" ;;
        "iPhone 12 Pro") DEVICE_MODEL_CODE="iPhone13,3" ;;
        "iPhone 12") DEVICE_MODEL_CODE="iPhone13,2" ;;
        "iPhone 13 mini") DEVICE_MODEL_CODE="iPhone14,4" ;;
        "iPhone 12 mini") DEVICE_MODEL_CODE="iPhone13,1" ;;
        *) DEVICE_MODEL_CODE="" ;;
      esac
    fi
    local sw_major=$(rand_int 2 3)
    local sw_minor=$(rand_int 0 9)
    QT_SOFTWARE=$(printf "VN %d.%d" "$sw_major" "$sw_minor")
    if [ "$(rand_int 0 1)" -eq 1 ]; then
      local sw_patch=$(rand_int 0 9)
      QT_SOFTWARE=$(printf "VN %d.%d.%d" "$sw_major" "$sw_minor" "$sw_patch")
    fi
  fi

  # UID
  if command -v uuidgen >/dev/null 2>&1; then
    UID_HEX=$(uuidgen | sed 's/-//g' | cut -c1-8)
  else
    UID_HEX=$(printf "%08X" "$(rand_uint32)")
  fi
  UID_TAG="UID-${UID_HEX}_$(rand_uint32)"

  CROP_TOTAL_W=$((CROP_W * 2))
  CROP_TOTAL_H=$((CROP_H * 2))
  if [ "$CROP_TOTAL_W" -gt 0 ]; then PAD_X=$(rand_int 0 "$CROP_TOTAL_W"); else PAD_X=0; fi
  if [ "$CROP_TOTAL_H" -gt 0 ]; then PAD_Y=$(rand_int 0 "$CROP_TOTAL_H"); else PAD_Y=0; fi

  VF="setpts=${STRETCH_FACTOR}*PTS,scale=${TARGET_W}:${TARGET_H}:flags=lanczos,setsar=1"
  VF="${VF},eq=brightness=0.005:saturation=1.01"
  if [ "$NOISE" -eq 1 ]; then VF="${VF},noise=alls=1:allf=t"; fi
  if [ "$CROP_TOTAL_W" -gt 0 ] || [ "$CROP_TOTAL_H" -gt 0 ]; then
    CROP_WIDTH=$((TARGET_W - CROP_TOTAL_W))
    CROP_HEIGHT=$((TARGET_H - CROP_TOTAL_H))
    if [ "$CROP_WIDTH" -lt 16 ]; then CROP_WIDTH=$((TARGET_W - CROP_W)); fi
    if [ "$CROP_HEIGHT" -lt 16 ]; then CROP_HEIGHT=$((TARGET_H - CROP_H)); fi
    if [ "$CROP_WIDTH" -lt 16 ]; then CROP_WIDTH=$TARGET_W; fi
    if [ "$CROP_HEIGHT" -lt 16 ]; then CROP_HEIGHT=$TARGET_H; fi
    VF="${VF},crop=${CROP_WIDTH}:${CROP_HEIGHT}:${CROP_X}:${CROP_Y}"
    VF="${VF},pad=${TARGET_W}:${TARGET_H}:${PAD_X}:${PAD_Y}:black"
  fi
  if [ "$MIRROR_ACTIVE" -eq 1 ]; then
    VF="${VF},${MIRROR_FILTER}"
  fi
  if [ "$LUT_ACTIVE" -eq 1 ] && [ -n "$LUT_FILTER" ]; then
    VF="${VF},${LUT_FILTER}"
  fi
  VF="${VF},drawtext=text='${UID_TAG}':fontcolor=white@0.08:fontsize=16:x=10:y=H-30"

  if [ -z "${CLIP_DURATION:-}" ]; then
    CLIP_DURATION="1.0"
  fi

  if ! awk -v d="$CLIP_DURATION" 'BEGIN{exit (d>0?0:1)}'; then
    CLIP_DURATION="$TARGET_DURATION"
  fi

  if [ -z "${CLIP_START:-}" ]; then
    CLIP_START="0.0"
  fi

  case "$CLIP_START" in
    *[[:space:]]*)
      CLIP_START="0.0"
      ;;
  esac

  FFMPEG_CMD=(ffmpeg -y -hide_banner -loglevel warning -ss "$CLIP_START" -i "$SRC")
  if [ "$MUSIC_VARIANT" -eq 1 ] && [ -n "$MUSIC_VARIANT_TRACK" ]; then
    FFMPEG_CMD+=(-ss "$CLIP_START" -i "$MUSIC_VARIANT_TRACK" -map 0:v:0 -map 1:a:0 -shortest)
  fi
  FFMPEG_CMD+=(-t "$CLIP_DURATION" -c:v libx264 -preset slow -profile:v "$VIDEO_PROFILE" -level "$VIDEO_LEVEL" -crf "$CRF"
    -r "$FPS" -b:v "${BR}k" -maxrate "${MAXRATE}k" -bufsize "${BUFSIZE}k"
    -vf "$VF"
    -c:a aac -b:a "$AUDIO_BR" -ar "$AUDIO_SR" -ac 2 -af "$AFILTER"
    -movflags +faststart
    -metadata encoder="$ENCODER_TAG"
    -metadata software="$SOFTWARE_TAG"
    -metadata creation_time="$CREATION_TIME"
    -metadata title="$TITLE"
    -metadata description="$DESCRIPTION"
    -metadata comment="$UID_TAG"
    "$ENCODE_TARGET")

  if [ "$DEBUG" -eq 1 ]; then
    echo "DEBUG copy=$copy_index seed=$SEED fps=$FPS br=${BR}k crf=$CRF maxrate=${MAXRATE}k bufsize=${BUFSIZE}k clip_start=${CLIP_START}s target_duration=$TARGET_DURATION stretch=$STRETCH_FACTOR audio=$AUDIO_PROFILE af='$AFILTER' music_track=${MUSIC_VARIANT_TRACK:-none} noise=$NOISE crop=${CROP_W}x${CROP_H}@${CROP_X},${CROP_Y} pad=${PAD_X},${PAD_Y} quality=$QUALITY mirror=${MIRROR_DESC} lut=${LUT_DESC} intro=${INTRO_DESC}"
  fi

  echo "▶️ [$copy_index/$COUNT] $SRC → $OUT | fps=$FPS br=${BR}k noise=$NOISE crop=${CROP_W}x${CROP_H} duration=${TARGET_DURATION}s audio=${AUDIO_PROFILE} mirror=${MIRROR_DESC} lut=${LUT_DESC} intro=${INTRO_DESC}"

  local ffmpeg_cmd_preview
  ffmpeg_cmd_preview=$(printf '%q ' "${FFMPEG_CMD[@]}")
  ffmpeg_cmd_preview=${ffmpeg_cmd_preview% }
  echo "ℹ️ clip_start=$CLIP_START duration=$CLIP_DURATION"
  echo "ℹ️ ffmpeg command: $ffmpeg_cmd_preview"

  "${FFMPEG_CMD[@]}"

  if [ "$INTRO_ACTIVE" -eq 1 ] && [ -n "$INTRO_SOURCE" ] && [ -n "$INTRO_OUTPUT_PATH" ]; then
    ffmpeg -y -hide_banner -loglevel warning -t "$INTRO_DURATION" -i "$INTRO_SOURCE" \
      -vf "scale=${TARGET_W}:${TARGET_H}:flags=lanczos,setsar=1" \
      -r "$FPS" -c:v libx264 -preset slow -profile:v "$VIDEO_PROFILE" -level "$VIDEO_LEVEL" -crf "$CRF" \
      -c:a aac -b:a "$AUDIO_BR" -ar "$AUDIO_SR" -ac 2 \
      -af "aresample=${AUDIO_SR},apad,atrim=0:${INTRO_DURATION}" -movflags +faststart "$INTRO_OUTPUT_PATH"
    CONCAT_LIST_FILE=$(mktemp "${OUTPUT_DIR}/.intro_concat_XXXXXX.txt")
    {
      printf "file '%s'\n" "$INTRO_OUTPUT_PATH"
      printf "file '%s'\n" "$ENCODE_TARGET"
    } > "$CONCAT_LIST_FILE"
    ffmpeg -y -hide_banner -loglevel warning -f concat -safe 0 -i "$CONCAT_LIST_FILE" -c copy -movflags +faststart "$FINAL_OUT"
    rm -f "$CONCAT_LIST_FILE" "$INTRO_OUTPUT_PATH"
    rm -f "$ENCODE_TARGET"
    OUT="$FINAL_OUT"
  else
    OUT="$ENCODE_TARGET"
  fi

  EXIF_CMD=(
    exiftool
    -overwrite_original
    -GPS:all=
    -Location:all=
    -SerialNumber=
    -Software="$SOFTWARE_TAG"
    -CreateDate="$CREATION_TIME_EXIF"
    -ModifyDate="$CREATION_TIME_EXIF"
    -QuickTime:CreateDate="$CREATION_TIME_EXIF"
    -QuickTime:ModifyDate="$CREATION_TIME_EXIF"
  )
  if [ "$QT_META" -eq 1 ]; then
    if [ "$DEVICE_INFO" -eq 1 ]; then
      if [ -n "$QT_MAKE" ]; then
        EXIF_CMD+=(-Make="$QT_MAKE")
      fi
      local model_payload=""
      if [ -n "$DEVICE_MODEL_CODE" ]; then
        model_payload="$DEVICE_MODEL_CODE"
      elif [ -n "$QT_MODEL" ]; then
        model_payload="$QT_MODEL"
      fi
      if [ -n "$model_payload" ]; then
        EXIF_CMD+=(-Model="$model_payload")
      fi
      if [ -n "$QT_MAKE" ] && [ -n "$QT_MODEL" ]; then
        EXIF_CMD+=(-QuickTime:Make="$QT_MAKE" -QuickTime:Model="$QT_MODEL" -QuickTime:com.apple.quicktime.make="$QT_MAKE" -QuickTime:com.apple.quicktime.model="$QT_MODEL")
      fi
    fi
    if [ -n "$QT_SOFTWARE" ]; then
      EXIF_CMD+=(-QuickTime:com.apple.quicktime.software="$QT_SOFTWARE")
    fi
  fi
  EXIF_CMD+=("$OUT")
  "${EXIF_CMD[@]}" >/dev/null

  touch_randomize_mtime "$OUT"
  FILE_NAME="$(basename "$OUT")"
  local MEDIA_DURATION_RAW=""
  local MEDIA_DURATION_SEC=""
  MEDIA_DURATION_RAW=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || true)
  local PREVIEW_NAME=""
  local PREVIEW_PATH="${PREVIEW_DIR}/${FILE_STEM}.png"
  if [ -n "$MEDIA_DURATION_RAW" ] && [ "$MEDIA_DURATION_RAW" != "N/A" ]; then
    MEDIA_DURATION_SEC=$(awk -v d="$MEDIA_DURATION_RAW" 'BEGIN{if(d==""||d=="N/A"){exit 1}; d+=0; if(d<0) d=0; printf "%.6f", d}' 2>/dev/null || printf "")
    if [ -z "$MEDIA_DURATION_SEC" ]; then
      echo "⚠️ Не удалось преобразовать длительность $FILE_NAME (${MEDIA_DURATION_RAW}) для проверки превью"
      MEDIA_DURATION_SEC=""
    fi
  else
    if [ -z "$MEDIA_DURATION_RAW" ] || [ "$MEDIA_DURATION_RAW" = "N/A" ]; then
      echo "⚠️ Не удалось определить длительность $FILE_NAME перед генерацией превью"
    fi
    MEDIA_DURATION_RAW=""
  fi

  local preview_seek_value="$PREVIEW_SS_NORMALIZED"
  local preview_seek_seconds=""
  preview_seek_seconds=$(ffmpeg_time_to_seconds "$preview_seek_value" 2>/dev/null || true)
  if [ -z "$preview_seek_seconds" ]; then
    preview_seek_value="$PREVIEW_SS_FALLBACK"
    preview_seek_seconds=$(ffmpeg_time_to_seconds "$preview_seek_value" 2>/dev/null || true)
  fi
  if [ -z "$preview_seek_seconds" ]; then
    echo "⚠️ Превью для $FILE_NAME: не удалось интерпретировать значение времени '${preview_seek_value}', используется 0.000"
    preview_seek_value="0.000"
    preview_seek_seconds="0.000"
  fi

  if [ -n "$MEDIA_DURATION_SEC" ] && [ -n "$preview_seek_seconds" ]; then
    if ! awk -v seek="$preview_seek_seconds" -v dur="$MEDIA_DURATION_SEC" 'BEGIN{exit (dur>0 && seek<dur ? 0 : 1)}'; then
      local preview_seek_seconds_fmt=""
      preview_seek_seconds_fmt=$(awk -v s="$preview_seek_seconds" 'BEGIN{printf "%.3f", s+0}')
      local media_duration_fmt=""
      media_duration_fmt=$(awk -v d="$MEDIA_DURATION_SEC" 'BEGIN{printf "%.3f", d+0}')
      echo "⚠️ Превью для $FILE_NAME: время ${preview_seek_value} (≈${preview_seek_seconds_fmt}s) выходит за пределы длительности ${media_duration_fmt}s"
      local adjusted_seek=""
      adjusted_seek=$(awk -v dur="$MEDIA_DURATION_SEC" 'BEGIN{if(dur<=0){printf "0.000"; exit} adj=dur-0.250; if(adj<0) adj=0; printf "%.3f", adj}')
      preview_seek_value="$adjusted_seek"
      preview_seek_seconds="$adjusted_seek"
      preview_seek_seconds_fmt=$(awk -v s="$preview_seek_seconds" 'BEGIN{printf "%.3f", s+0}')
      echo "ℹ️ Превью для $FILE_NAME будет взято по скорректированному времени ${preview_seek_seconds_fmt}s"
    fi
  fi

  if [ "$DEBUG" -eq 1 ]; then
    local media_duration_dbg="unknown"
    if [ -n "$MEDIA_DURATION_SEC" ]; then
      media_duration_dbg=$(awk -v d="$MEDIA_DURATION_SEC" 'BEGIN{printf "%.3f", d+0}')
    fi
    if [ -n "$preview_seek_seconds" ]; then
      local preview_seek_seconds_dbg="$(awk -v s="$preview_seek_seconds" 'BEGIN{printf "%.3f", s+0}')"
      echo "DEBUG preview_ss=${preview_seek_value} (~${preview_seek_seconds_dbg}s) duration=${media_duration_dbg}s"
    else
      echo "DEBUG preview_ss=${preview_seek_value} duration=${media_duration_dbg}s (seconds unresolved)"
    fi
  fi

  if ffmpeg -y -hide_banner -loglevel error -ss "$preview_seek_value" -i "$OUT" -vframes 1 "$PREVIEW_PATH"; then
    if [ -s "$PREVIEW_PATH" ]; then
      PREVIEW_NAME="previews/${FILE_STEM}.png"
    else
      echo "⚠️ Превью для $FILE_NAME пустое"
      rm -f "$PREVIEW_PATH"
    fi
  else
    echo "⚠️ Не удалось создать превью для $FILE_NAME"
    rm -f "$PREVIEW_PATH" 2>/dev/null || true
  fi
  BITRATE_RAW=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$OUT")
  BITRATE=$(awk -v b="$BITRATE_RAW" 'BEGIN{if(b==""||b=="N/A") printf "0"; else printf "%.0f", b/1000}')
  DURATION_RAW="$MEDIA_DURATION_RAW"
  if [ -z "$DURATION_RAW" ]; then
    DURATION_RAW=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT")
  fi
  DURATION=$(awk -v d="$DURATION_RAW" 'BEGIN{if(d==""||d=="N/A") printf "0"; else printf "%.3f", d}')
  SIZE_BYTES=$(file_size_bytes "$OUT")
  SIZE_KB=$(awk -v s="$SIZE_BYTES" 'BEGIN{if(s==""||s==0) printf "0"; else printf "%.0f", s/1024}')
  RUN_FILES+=("$FILE_NAME")
  RUN_BITRATES+=("$BITRATE")
  RUN_FPS+=("$FPS")
  RUN_DURATIONS+=("$DURATION")
  RUN_SIZES+=("$SIZE_KB")
  RUN_ENCODERS+=("$ENCODER_TAG")
  RUN_SOFTWARES+=("$SOFTWARE_TAG")
  RUN_CREATION_TIMES+=("$CREATION_TIME")
  RUN_SEEDS+=("$SEED")
  RUN_TARGET_DURS+=("$TARGET_DURATION")
  RUN_TARGET_BRS+=("$BR")
  RUN_COMBOS+=("$combo_key")
  RUN_PROFILES+=("$PROFILE_VALUE")
  RUN_QUALITIES+=("$QUALITY")
  RUN_QT_MAKES+=("$QT_MAKE")
  RUN_QT_MODELS+=("$QT_MODEL")

  RUN_QT_SOFTWARES+=("$QT_SOFTWARE")
  RUN_CREATIVE_MIRROR+=("$MIRROR_DESC")
  RUN_CREATIVE_INTRO+=("$INTRO_DESC")
  RUN_CREATIVE_LUT+=("$LUT_DESC")
  RUN_PREVIEWS+=("$PREVIEW_NAME")

  local metrics
  metrics=$(compute_metrics_for_copy "$SRC" "$OUT")
  local rest
  RUN_SSIM+=("${metrics%%|*}")
  rest=${metrics#*|}
  RUN_PSNR+=("${rest%%|*}")
  RUN_PHASH+=("${rest#*|}")

  echo "✅ done: $OUT"
}

for ((i=1;i<=COUNT;i++)); do
  generate_copy "$i" "$REGEN_ITER"
done

fallback_attempts=0
while low_uniqueness_fallback; do
  fallback_attempts=$((fallback_attempts + 1))
  if [ "$fallback_attempts" -ge 2 ]; then
    break
  fi
done

quality_round=0
quality_pass_all=false
while :; do
  regen_attempts=0
  threshold=$(duplicate_threshold "${#RUN_FILES[@]}")
  max_dup=0
  while :; do
    max_dup=$(calculate_duplicate_max RUN_FPS RUN_BITRATES RUN_DURATIONS)
    if [ "$max_dup" -lt "$threshold" ]; then
      break
    fi
    if [ "$regen_attempts" -ge "$MAX_REGEN_ATTEMPTS" ]; then
      echo "⚠️ После повторных попыток остаются похожие копии (max=$max_dup)"
      break
    fi
    REGEN_OCCURRED=1
    regen_attempts=$((regen_attempts + 1))
    echo "⚠️ Обнаружены слишком похожие копии, выполняется перегенерация…"
    local_regen_count=3
    if [ "$local_regen_count" -gt "${#RUN_FILES[@]}" ]; then
      local_regen_count="${#RUN_FILES[@]}"
    fi
    remove_last_generated "$local_regen_count"
    REGEN_ITER=$((REGEN_ITER + 1))
    start_index=$((COUNT - local_regen_count + 1))
    for ((idx=start_index; idx<=COUNT; idx++)); do
      generate_copy "$idx" "$REGEN_ITER"
    done
  done

  local fallback_happened=0
  while low_uniqueness_fallback; do
    fallback_happened=1
    fallback_attempts=$((fallback_attempts + 1))
    if [ "$fallback_attempts" -ge 3 ]; then
      break
    fi
  done
  if [ "$fallback_happened" -eq 1 ]; then
    continue
  fi

  validated_flag=true
  if [ "$max_dup" -ge "$threshold" ]; then
    validated_flag=false
  fi

  quality_check
  if [ "${#QUALITY_ISSUES[@]}" -eq 0 ]; then
    quality_pass_all=true
    break
  fi
  if [ "$quality_round" -ge 1 ]; then
    echo "⚠️ Качество остаётся подозрительным, перегенерация прекращена"
    break
  fi
  quality_round=$((quality_round + 1))
  REGEN_OCCURRED=1
  echo "⚠️ Перегенерация по качеству: ${#QUALITY_ISSUES[@]} копий"
  remove_indices_for_regen "${QUALITY_ISSUES[@]}"
  REGEN_ITER=$((REGEN_ITER + 1))
  for copy_id in "${QUALITY_COPY_IDS[@]}"; do
    generate_copy "$copy_id" "$REGEN_ITER"
  done
done

if [ "$quality_pass_all" != true ]; then
  quality_check
fi

warn_similar_copies

regen_flag=false
if [ "$REGEN_OCCURRED" -eq 1 ]; then
  regen_flag=true
fi

for idx in "${!RUN_FILES[@]}"; do

  echo "${RUN_FILES[$idx]},${RUN_BITRATES[$idx]},${RUN_FPS[$idx]},${RUN_DURATIONS[$idx]},${RUN_SIZES[$idx]},${RUN_ENCODERS[$idx]},${RUN_SOFTWARES[$idx]},${RUN_CREATION_TIMES[$idx]},${RUN_SEEDS[$idx]},${RUN_TARGET_DURS[$idx]},${RUN_TARGET_BRS[$idx]},$validated_flag,$regen_flag,${RUN_PROFILES[$idx]},${RUN_QT_MAKES[$idx]},${RUN_QT_MODELS[$idx]},${RUN_QT_SOFTWARES[$idx]},${RUN_SSIM[$idx]},${RUN_PHASH[$idx]},${RUN_QPASS[$idx]},${RUN_QUALITIES[$idx]},${RUN_CREATIVE_MIRROR[$idx]},${RUN_CREATIVE_INTRO[$idx]},${RUN_CREATIVE_LUT[$idx]},${RUN_PREVIEWS[$idx]}" >> "$MANIFEST_PATH"

  echo "${RUN_FILES[$idx]},${RUN_BITRATES[$idx]},${RUN_FPS[$idx]},${RUN_DURATIONS[$idx]},${RUN_SIZES[$idx]},${RUN_ENCODERS[$idx]},${RUN_SOFTWARES[$idx]},${RUN_CREATION_TIMES[$idx]},${RUN_SEEDS[$idx]},${RUN_TARGET_DURS[$idx]},${RUN_TARGET_BRS[$idx]},$validated_flag,$regen_flag,${RUN_PROFILES[$idx]},${RUN_QT_MAKES[$idx]},${RUN_QT_MODELS[$idx]},${RUN_SSIM[$idx]},${RUN_PSNR[$idx]},${RUN_PHASH[$idx]},${RUN_QPASS[$idx]},${RUN_QUALITIES[$idx]}" >> "$MANIFEST_PATH"

done

report_template_statistics

run_self_audit_pipeline() {
  local scripts=("collect_meta.sh" "quality_check.sh")
  local script
  for script in "${scripts[@]}"; do
    if [ -f "${BASE_DIR}/${script}" ]; then
      chmod +x "${BASE_DIR}/${script}" 2>/dev/null || true
      (cd "$BASE_DIR" && ./"$script") || echo "⚠️ ${script} завершился с ошибкой"
    else
      echo "⚠️ ${script} не найден"
    fi
  done

  local phash_log="${CHECK_DIR}/phash_raw.log"
  : > "$phash_log"

  local phash_script="${BASE_DIR}/phash_check.py"
  if [ -f "$phash_script" ]; then
    while IFS= read -r -d '' video_file; do
      python3 "$phash_script" "$SRC" "$video_file" >>"$phash_log" 2>&1 || \
        echo "⚠️ pHash check failed for ${video_file##*/}" >>"$phash_log"
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.mp4' -print0)
  else
    echo "⚠️ phash_check.py не найден"
  fi

  local audit_script="${BASE_DIR}/uniclon_audit.sh"
  if [ -f "$audit_script" ]; then
    chmod +x "$audit_script" 2>/dev/null || true
    (cd "$BASE_DIR" && ./"${audit_script##*/}") || echo "⚠️ uniclon_audit.sh завершился с ошибкой"
  else
    echo "⚠️ uniclon_audit.sh не найден"
  fi
}

run_self_audit_pipeline

if [ "$LOW_UNIQUENESS_TRIGGERED" -eq 1 ]; then
  printf '⚠️ Low uniqueness fallback triggered.' >"$LOW_UNIQUENESS_FLAG"
fi

if [ "$AUTO_CLEAN" -eq 1 ]; then
  cleanup_temp_artifacts
fi

echo "All done. Outputs in: $OUTPUT_DIR | Manifest: $MANIFEST_PATH"
