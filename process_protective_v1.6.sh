#!/bin/bash
# Безопасный режим исполнения
set -euo pipefail
trap 'rc=$?; echo "[SAFE EXIT] Process terminated (code $rc)"; exit $rc' ERR

# Определение абсолютного пути скрипта
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
# --- Safe runtime init ---
if [ -d "$BASE_DIR/modules" ]; then
  for mod in "$BASE_DIR/modules/"*.sh; do
    [ -f "$mod" ] && . "$mod"
  done
fi

. "$BASE_DIR/modules/time_utils.sh" || { echo "[FATAL] Failed to load time_utils.sh"; exit 127; }

type clip_start >/dev/null 2>&1 || { echo "[FATAL] clip_start() missing after init"; exit 127; }
echo "[SAFE INIT] Modules sourced successfully"
IFS=$'\n\t'

SOFTWARE_POOL=(
  "CapCut 12.3.3"
  "VN 2.14.2"
  "InShot 1.920"
  "Clips 3.2.1"
  "Filmora 12.1.0"
  "Mobile Camera 1.0"
)

BRAND_TAGS=("mp42" "isom" "iso6" "avc1")

TARGET_FPS_INPUT="${TARGET_FPS:-}"
TARGET_FPS=${TARGET_FPS:-30}
AUDIO_INTENSITY="${AUDIO_INTENSITY:-medium}" # gentle | medium | strong

# process_protective_v1.6.sh (macOS совместимая версия)
# Делает N уникальных копий из одного видео, сохраняет в OUTPUT_DIR/
chmod +x "$BASE_DIR"/modules/*.sh 2>/dev/null || true
export OUTPUT_DIR="${OUTPUT_DIR:-$BASE_DIR/output}"
mkdir -p "$OUTPUT_DIR"
LOG_DIR="$OUTPUT_DIR/logs"
LOG_FILE="$LOG_DIR/last_run.log"
mkdir -p "$LOG_DIR"
: >"$LOG_FILE"
. "$BASE_DIR/bootstrap_compat.sh"
. "$BASE_DIR/modules/fallback_manager.sh"
. "$BASE_DIR/modules/manifest.sh"
. "$BASE_DIR/modules/generate_copy.sh"
bootstrap_init "${BASH_SOURCE[0]}"

echo "[INIT] Modular mode active — cleaned and sandboxed"
echo "[INIT] Modular cleanup complete — orchestrator verified"
# REGION AI: runtime state arrays
declare -a RUN_COMBOS=()
declare -a RUN_COMBO_HISTORY RUN_FILES RUN_BITRATES RUN_FPS RUN_DURATIONS RUN_SIZES RUN_ENCODERS RUN_SOFTWARES RUN_CREATION_TIMES RUN_SEEDS RUN_TARGET_DURS RUN_TARGET_BRS RUN_PROFILES RUN_QT_MAKES RUN_QT_MODELS RUN_QT_SOFTWARES RUN_SSIM RUN_PSNR RUN_PHASH RUN_UNIQ RUN_QPASS RUN_QUALITIES RUN_CREATIVE_MIRROR RUN_CREATIVE_INTRO RUN_CREATIVE_LUT RUN_PREVIEWS
RUN_COMBO_HISTORY=()
# REGION AI: fallback status tracker
fallback_status=""
# END REGION AI
# END REGION AI

DEBUG=0
MUSIC_VARIANT=0
PROFILE=""
QT_META=1
STRICT_CLEAN=0
QUALITY="std"
AUTO_CLEAN=0
TARGET_FPS_ENV="${TARGET_FPS_INPUT:-}"
ENABLE_MIRROR=${ENABLE_MIRROR:-0}
ENABLE_INTRO=${ENABLE_INTRO:-0}
ENABLE_LUT=${ENABLE_LUT:-0}
DEVICE_INFO=1
DRY_RUN=${DRY_RUN:-0}
if ! parse_args "$@"; then
  exit 1
fi
set -- "${POSITIONAL_ARGS[@]}"

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
: "${UNICLON_AUDIO_EQ_OVERRIDE:=}"
: "${PREVIEW_SS:=00:00:01.000}"
# END REGION AI
audio_init_filter_caps

PREVIEW_SS_FALLBACK="00:00:01.000"
# Нормализованное значение времени превью вычисляется позже через clip_start
PREVIEW_SS_NORMALIZED=""

if [ "$STRICT_CLEAN" -eq 1 ]; then
  QT_META=0
fi

# REGION AI: output manifest configuration
MANIFEST="manifest.csv"
MANIFEST_PATH="${OUTPUT_DIR}/${MANIFEST}"
# END REGION AI
# REGION AI: vertical platform presets
TARGET_W=1080
TARGET_H=1920
PROFILE_BR_MIN=2800
PROFILE_BR_MAX=5000
BR_MIN=$PROFILE_BR_MIN
BR_MAX=$PROFILE_BR_MAX
FPS_BASE=(30)
FPS_RARE=()
AUDIO_SR_OPTIONS=(44100)
AUDIO_SR=44100
PROFILE_FORCE_FPS=""
PROFILE_MAX_DURATION=0
VIDEO_PROFILE="high"
VIDEO_LEVEL="4.0"
PROFILE_LABEL="Default"

case "$PROFILE" in
  tiktok)
    PROFILE_LABEL="TikTok"
    TARGET_W=1080
    TARGET_H=1920
    PROFILE_BR_MIN=2800
    PROFILE_BR_MAX=5000
    FPS_BASE=(30 60)
    FPS_RARE=()
    AUDIO_SR_OPTIONS=(44100)
    PROFILE_MAX_DURATION=60
    VIDEO_PROFILE="high"
    VIDEO_LEVEL="4.0"
    ;;
  instagram)
    PROFILE_LABEL="Instagram"
    TARGET_W=1080
    TARGET_H=1920
    PROFILE_BR_MIN=2500
    PROFILE_BR_MAX=4500
    FPS_BASE=(24 25 30)
    FPS_RARE=()
    AUDIO_SR_OPTIONS=(44100)
    PROFILE_MAX_DURATION=60
    VIDEO_PROFILE="high"
    VIDEO_LEVEL="4.0"
    ;;
  youtube)
    PROFILE_LABEL="YouTube Shorts"
    TARGET_W=1080
    TARGET_H=1920
    PROFILE_BR_MIN=3000
    PROFILE_BR_MAX=5500
    FPS_BASE=(24 30 60)
    FPS_RARE=()
    AUDIO_SR_OPTIONS=(44100 48000)
    PROFILE_MAX_DURATION=60
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

BR_MIN=$PROFILE_BR_MIN
BR_MAX=$PROFILE_BR_MAX
AUDIO_SR=${AUDIO_SR_OPTIONS[0]}
# END REGION AI
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
    # REGION AI: high quality bitrate bias
    span=$((PROFILE_BR_MAX - PROFILE_BR_MIN))
    if [ "$span" -lt 0 ]; then span=0; fi
    BR_MIN=$((PROFILE_BR_MIN + span / 2))
    if [ "$BR_MIN" -lt "$PROFILE_BR_MIN" ]; then BR_MIN=$PROFILE_BR_MIN; fi
    BR_MAX=$PROFILE_BR_MAX
    # END REGION AI
    ;;
  std|*)
    QUALITY="std"
    CRF=22
    BR_MIN=$PROFILE_BR_MIN
    BR_MAX=$PROFILE_BR_MAX
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Требуется $1"; exit 1; }; }
need ffmpeg
need ffprobe
need exiftool
need bc

FFMPEG_FILTER_CACHE=""

ffmpeg_filter_available() {
  local filter_name="${1:-}"
  if [ -z "$filter_name" ]; then
    return 1
  fi
  if [ -z "${FFMPEG_FILTER_CACHE:-}" ]; then
    if ! FFMPEG_FILTER_CACHE="$(ffmpeg -hide_banner -filters 2>/dev/null)"; then
      FFMPEG_FILTER_CACHE=""
    fi
  fi
  if [ -z "$FFMPEG_FILTER_CACHE" ]; then
    return 1
  fi
  printf '%s\n' "$FFMPEG_FILTER_CACHE" | grep -E "[[:space:]]${filter_name}([[:space:]]|$)" >/dev/null 2>&1
}

usage() { echo "Usage: $0 <input_video> [count]"; exit 1; }
[ "${1:-}" ] || usage
SRC="$1"
[ -f "$SRC" ] || { echo "❌ Нет файла: $SRC"; exit 1; }
INPUT_FILE="$SRC"
COUNT="${2:-1}"
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "❌ count должен быть числом"; exit 1; }
TOTAL_COPIES="$COUNT"
SUCCESS_COUNT=0
FAILED_COUNT=0
TRUST_SCORE=1.00

SRC_BITRATE="None"
SRC_BITRATE_RAW=$(ffprobe_exec -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$SRC" 2>/dev/null || true)
if [ -n "$SRC_BITRATE_RAW" ] && awk -v val="$SRC_BITRATE_RAW" 'BEGIN{val+=0; exit (val>0 ? 0 : 1)}'; then
  SRC_BITRATE=$(awk -v val="$SRC_BITRATE_RAW" 'BEGIN{printf "%.0f", val/1000}')
fi

ensure_dir "$OUTPUT_DIR"
OUTPUT_LOG="${OUTPUT_LOG:-$OUTPUT_DIR/process.log}"
: >"$OUTPUT_LOG"

AUDIO_MODE="normal"

cleanup_output_dir_on_failure() {
  local out_dir="${OUTPUT_DIR:-}"
  if [ -z "$out_dir" ] || [ ! -d "$out_dir" ]; then
    return
  fi
  while IFS= read -r -d '' entry; do
    if [ -d "$entry" ]; then
      rm -rf "$entry" 2>/dev/null || true
    else
      rm -f "$entry" 2>/dev/null || true
    fi
  done < <(find "$out_dir" -mindepth 1 -maxdepth 1 ! -path "$out_dir/logs" -print0)
}

validate_audio() {
  local input_file="${1:-}" 
  if [ -z "$input_file" ]; then
    AUDIO_MODE="mute"
    return
  fi
  local audio_present
  if ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$input_file" 2>/dev/null | grep -q audio; then
    audio_present=1
  else
    audio_present=0
  fi
  if [ "$audio_present" -eq 0 ]; then
    echo "[WARN] No audio stream detected — switching to silent mode."
    AUDIO_MODE="mute"
  else
    AUDIO_MODE="normal"
  fi
}

validate_audio "$INPUT_FILE"

manifest_init "$MANIFEST_PATH"

CURRENT_COPY_INDEX=0
 
PREVIEW_SS_NORMALIZED=$(clip_start "$PREVIEW_SS" "$PREVIEW_SS_FALLBACK" "preview_ss" "init")
if [ -z "$PREVIEW_SS_NORMALIZED" ]; then
  PREVIEW_SS_NORMALIZED="$PREVIEW_SS_FALLBACK"
fi

log_warn() {
  log "⚠️" "$@"
}
# END REGION AI

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

base="$(basename "$SRC")"
name="${base%.*}"
BASENAME="$name"

ORIG_DURATION=$(ffprobe_exec -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SRC")
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
declare -a RUN_COMBO_HISTORY=()
declare -a RUN_PROFILES=()
declare -a RUN_QUALITIES=() RUN_FALLBACK_REASON=() RUN_COMBO_USED=() RUN_ATTEMPTS=()
declare -a RUN_QT_MAKES=()
declare -a RUN_QT_MODELS=()
declare -a RUN_QT_SOFTWARES=()
declare -a RUN_SSIM=()
declare -a RUN_UNIQ=()
declare -a RUN_PSNR=()
declare -a RUN_PHASH=()
declare -a RUN_TRUST_SCORE=()
declare -a RUN_QPASS=()
declare -a RUN_CREATIVE_MIRROR=()
declare -a RUN_CREATIVE_INTRO=()
declare -a RUN_CREATIVE_LUT=()
declare -a RUN_PREVIEWS=()
declare -a RUN_FS_TIMESTAMPS=()
declare -a QUALITY_ISSUES=()
declare -a QUALITY_COPY_IDS=()
: "${RANDOMIZATION_SALT:=uniclon_v1.7}"
# REGION AI: container metadata placeholders
MAJOR_BRAND_TAG="mp42"
MINOR_VERSION_TAG="0"
COMPAT_BRANDS_TAG="isommp42"
# END REGION AI
USED_SOFT_ENC_KEYS_LIST=""
# REGION AI: variant uniqueness state
declare -a RUN_VARIANT_KEYS=()
USED_VARIANT_KEYS_LIST=""
CURRENT_VARIANT_KEY=""
# END REGION AI

REGEN_ITER=0
REGEN_OCCURRED=0
LOW_UNIQUENESS_TRIGGERED=0
MAX_REGEN_ATTEMPTS=2; RUN_COMBO_POS=0

# REGION AI: uniqueness combo orchestration
# (moved to modules/combo_engine.sh)

combo_engine_autofill
for ((i=1;i<=COUNT;i++)); do
  generate_copy "$i" "$REGEN_ITER"
done

auto_expand_run_combos

fallback_attempts=0
while fallback_process_cycle 2; do
  auto_expand_run_combos
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
      # REGION AI: variant similarity guard
      variant_share=$(variant_max_share RUN_VARIANT_KEYS)
      if awk -v share="$variant_share" 'BEGIN{exit !(share>0.70)}'; then
        if [ "$regen_attempts" -ge "$MAX_REGEN_ATTEMPTS" ]; then
          echo "⚠️ >70% копий имеют одинаковые параметры, повторная генерация остановлена"
          break
        fi
        REGEN_OCCURRED=1
        regen_attempts=$((regen_attempts + 1))
        echo "⚠️ Обнаружена высокая схожесть параметров, перегенерация выбранных копий…"
        local_regen_count=2
        if [ "$local_regen_count" -gt "${#RUN_FILES[@]}" ]; then
          local_regen_count="${#RUN_FILES[@]}"
        fi
        remove_last_generated "$local_regen_count"
        REGEN_ITER=$((REGEN_ITER + 1))
        start_index=$((COUNT - local_regen_count + 1))
        for ((idx=start_index; idx<=COUNT; idx++)); do
          generate_copy "$idx" "$REGEN_ITER"
        done
        continue
      fi
      # END REGION AI
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

  if fallback_process_cycle 2; then
    continue
  fi

  validated_flag=true
  if [ "$max_dup" -ge "$threshold" ]; then
    validated_flag=false
  fi

  metrics_quality_check
  if [ "${#QUALITY_ISSUES[@]}" -eq 0 ]; then
    quality_pass_all=true
    break
  fi
  if [ "$quality_round" -ge 1 ]; then
    echo "⚠️ Качество остаётся подозрительным, перегенерация прекращена"
    break
  fi
  quality_round=$((quality_round + 1))
  fallback_try_regen_quality
done

if [ "$quality_pass_all" != true ]; then
  metrics_quality_check
fi

metrics_warn_similar_copies; metrics_log_uniqueness_summary

regen_flag=false
if [ "$REGEN_OCCURRED" -eq 1 ]; then
  regen_flag=true
fi

report_builder_template_statistics "$MANIFEST_PATH"



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

SUCCESS_COUNT=${#RUN_FILES[@]}
echo "✅ Успешно: $SUCCESS_COUNT/$TOTAL_COPIES"
echo "⚠️ Ошибки: $FAILED_COUNT"
if [ "${#RUN_TRUST_SCORE[@]}" -gt 0 ]; then
  TRUST_SCORE=$(printf '%s\n' "${RUN_TRUST_SCORE[@]}" | awk -f - <<'AWK'
BEGIN {
  sum = 0;
  count = 0;
}

/^[0-9]+(\.[0-9]+)?$/ {
  sum += $1;
  count++;
}

END {
  if (count > 0) {
    printf "%.2f", sum / count;
  }
}
AWK
  )
  if [ -z "$TRUST_SCORE" ]; then
    TRUST_SCORE=1.00
  fi
fi
if [ "$FAILED_COUNT" -gt 0 ]; then
  TRUST_SCORE=$(awk -v score="$TRUST_SCORE" 'BEGIN{printf "%.2f", score * 0.6}')
fi
echo "TrustScore: $TRUST_SCORE"

echo "Audit Report:"
total_outputs=${#RUN_FILES[@]}
if [ "${#RUN_SOFTWARES[@]}" -gt 0 ]; then
  unique_soft=$(printf '%s\n' "${RUN_SOFTWARES[@]}" | sort -u | awk 'NF' | wc -l | awk '{print $1}')
  unique_enc=$(printf '%s\n' "${RUN_ENCODERS[@]}" | sort -u | awk 'NF' | wc -l | awk '{print $1}')
  if { [ "${unique_soft}" -gt 1 ] && [ "${unique_enc}" -gt 1 ]; } || [ "$total_outputs" -le 1 ]; then
    echo "✅ Encoder/software diversified"
  else
    echo "❌ Encoder/software diversified"
  fi
else
  echo "❌ Encoder/software diversified"
fi

if [ "${#RUN_FS_TIMESTAMPS[@]}" -gt 0 ]; then
  unique_ts=$(printf '%s\n' "${RUN_FS_TIMESTAMPS[@]}" | awk 'NF' | sort -u | wc -l | awk '{print $1}')
  if { [ "$unique_ts" -ge "$total_outputs" ] && [ "$total_outputs" -gt 0 ]; } || [ "$total_outputs" -le 1 ]; then
    echo "✅ Timestamps randomized"
  else
    echo "❌ Timestamps randomized"
  fi
else
  echo "❌ Timestamps randomized"
fi

if ! fallback_soft_finalize; then
  exit 1
fi

if [ "$LOW_UNIQUENESS_TRIGGERED" -eq 1 ]; then
  printf '⚠️ Low uniqueness fallback triggered.' >"$LOW_UNIQUENESS_FLAG"
fi

if [ "$AUTO_CLEAN" -eq 1 ]; then
  cleanup_temp_artifacts
fi

echo "All done. Outputs in: $OUTPUT_DIR | Manifest: $MANIFEST_PATH"

rc=${rc:-0}
if [ "$rc" -eq 255 ]; then
  echo '[FATAL] FFmpeg pipeline critical error — possible invalid input or filter crash'
  exit 255
fi
