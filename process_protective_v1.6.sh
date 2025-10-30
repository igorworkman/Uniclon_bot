#!/bin/bash
# Безопасный режим исполнения
set -euo pipefail

# Определение абсолютного пути скрипта
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
IFS=$'\n\t'

# process_protective_v1.6.sh (macOS совместимая версия)
# Делает N уникальных копий из одного видео, сохраняет в OUTPUT_DIR/
chmod +x "$BASE_DIR"/modules/*.sh 2>/dev/null || true
export OUTPUT_DIR="${OUTPUT_DIR:-$BASE_DIR/output}"
mkdir -p "$OUTPUT_DIR"
. "$BASE_DIR/bootstrap_compat.sh"
. "$BASE_DIR/modules/fallback_manager.sh"
. "$BASE_DIR/modules/manifest.sh"
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

usage() { echo "Usage: $0 <input_video> [count]"; exit 1; }
[ "${1:-}" ] || usage
SRC="$1"
[ -f "$SRC" ] || { echo "❌ Нет файла: $SRC"; exit 1; }
COUNT="${2:-1}"
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "❌ count должен быть числом"; exit 1; }

SRC_BITRATE="None"
SRC_BITRATE_RAW=$(ffprobe_exec -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$SRC" 2>/dev/null || true)
if [ -n "$SRC_BITRATE_RAW" ] && awk -v val="$SRC_BITRATE_RAW" 'BEGIN{val+=0; exit (val>0 ? 0 : 1)}'; then
  SRC_BITRATE=$(awk -v val="$SRC_BITRATE_RAW" 'BEGIN{printf "%.0f", val/1000}')
fi

ensure_dir "$OUTPUT_DIR"

manifest_init "$MANIFEST_PATH"

CURRENT_COPY_INDEX=0
 
escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/\\\\'/g"
}

build_filter() {
  local base="${1:-}"
  base="${base//(/\\(}"
  base="${base//)/\\)}"
  echo "$base"
}

PREVIEW_SS_NORMALIZED=$(clip_start "$PREVIEW_SS" "$PREVIEW_SS_FALLBACK" "preview_ss" "init")
if [ -z "$PREVIEW_SS_NORMALIZED" ]; then
  PREVIEW_SS_NORMALIZED="$PREVIEW_SS_FALLBACK"
fi

prepare_output_name() {
  local seed_value="" seed_hash="" prefix="VID"
  while :; do
    local days hours minutes seconds stamp raw_seed
    local -a default_pool=("VID" "VID" "IMG" "PXL")
    local -a ios_pool=("IMG" "IMG" "VID")
    local -a pixel_pool=("PXL" "PXL" "VID")
    days=$(rand_int 3 10)
    hours=$(rand_int 0 23)
    minutes=$(rand_int 0 59)
    seconds=$(rand_int 0 59)
    stamp=$(format_past_timestamp "%Y%m%d_%H%M%S" "$days" "$hours" "$minutes" "$seconds")
    if [ -z "$stamp" ]; then
      stamp=$(date -u +"%Y%m%d_%H%M%S")
    fi

    raw_seed="${RAND_SEED:-$SEED_HEX}"
    if [[ "$raw_seed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      seed_value=$(awk -v s="$raw_seed" 'BEGIN{ if (s<0) s=0; if (s>1) s=1; printf "%.3f", s+0 }')
      seed_hash=$(awk -v s="$raw_seed" 'BEGIN{ if (s<0) s=0; if (s>1) s=1; printf "%04x", int(s*65535) }')
    else
      local seed_int
      seed_int=$(printf '%d' "0x${SEED_HEX:0:4}")
      seed_hash=$(printf "%04x" "$seed_int")
      seed_value=$(awk -v v="$seed_int" 'BEGIN{ printf "%.3f", (v % 65536) / 65535 }')
    fi
    # Compatible with macOS Bash 3.2 — lowercase conversion via 'tr'
    seed_hash=$(echo "$seed_hash" | tr '[:upper:]' '[:lower:]')

    local hash_idx
    hash_idx=$(printf '%d' "0x${SEED_HEX:4:2}")
    local -a pool=("${default_pool[@]}")
    case "$SOFTWARE_TAG" in
      *iMovie*|*Final*Cut*) pool=("${ios_pool[@]}") ;;
      *Pixel*|*Google*) pool=("${pixel_pool[@]}") ;;
      *) pool=("${default_pool[@]}") ;;
    esac
    if [ ${#pool[@]} -gt 0 ]; then
      prefix="${pool[$((hash_idx % ${#pool[@]}))]}"
    else
      prefix="VID"
    fi

    OUT_NAME="${prefix}_${stamp}_${seed_hash}.mp4"
    OUT="${OUTPUT_DIR}/${OUT_NAME}"
    [ -e "$OUT" ] || break
  done
  FILE_STEM="${OUT_NAME%.*}"
  FILE_EXT="${OUT_NAME##*.}"
  CURRENT_SEED_PRINT="${seed_value:-0.000}"
  CURRENT_SEED_HASH="$seed_hash"
}

rand_description() {
  local choices=(
    "Edited on mobile"
    "Final export"
    "Captured on phone"
    "Shot in portrait"
    "Quick highlight"
    "Daily highlights"
    "Personal draft"
    "Travel vertical"
  )
  local idx=$(( $(rng_next_chunk) % ${#choices[@]} ))
  echo "${choices[$idx]}"
}

# REGION AI: lightweight randomized titles
rand_title() {
  local titles=(
    "Vertical clip"
    "Story highlight"
    "Quick reel"
    "Travel moment"
    "Daily snap"
    "Phone capture"
  )
  local idx=$(( $(rng_next_chunk) % ${#titles[@]} ))
  echo "${titles[$idx]}"
}
# END REGION AI

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
    youtube)
      combos=(
        "Apple|iPhone 13 Pro|iPhone14,2"
        "Apple|iPhone 14|iPhone15,2"
        "Samsung|Galaxy S22|SM-S901B"
        "Google|Pixel 7|GVU6C"
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

# REGION AI: ffmpeg audio filter guards
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

sanitize_audio_filters() {
  local chain="${1:-}"
  chain=$(printf '%s' "$chain" | sed -E 's/(^|,)atempo=(,|$)/\1/g')
  chain=$(printf '%s' "$chain" | sed -E 's/(^|,)anull(,|$)/\1/g')
  chain=$(printf '%s' "$chain" | sed -E 's/,{2,}/,/g')
  chain="${chain#,}"
  chain="${chain%,}"
  [ -z "$chain" ] && chain="anull"
  printf '%s' "$chain"
}

ensure_superequalizer_bounds() {
  local chain="${1:-}"
  if [[ "$chain" != *"superequalizer="* ]]; then
    printf '%s' "$chain"
    return
  fi
  python3 - "$chain" <<'PY_SAN'
import sys, re
chain = sys.argv[1]
def clamp(match):
    parts = match.group(1).split(':')
    bands = []
    for part in parts:
        if '=' in part:
            name, value = part.split('=', 1)
            try:
                num = float(value)
            except ValueError:
                bands.append(f"{name}={value}")
                continue
            if num < 0.0:
                num = 0.0
            elif num > 20.0:
                num = 20.0
            bands.append(f"{name}={num:.3f}")
        else:
            bands.append(part)
    return "superequalizer=" + ":".join(bands)
print(re.sub(r"superequalizer=([^,]+)", clamp, chain), end="")
PY_SAN
}

next_combo() {
  local payload
  payload=$(next_regen_combo)
  if [ -z "$payload" ]; then
    RUN_COMBO_POS=0
    payload=$(next_regen_combo)
  fi
  printf '%s' "$payload"
}

pick_software_encoder() {
  local profile_key="${1:-default}" attempt=0
  while :; do
    local prefer=$(rand_int 0 99)
    local family="CapCut"
    if [ -n "${CSOFT:-}" ]; then
      family="$CSOFT"
    else
      case "$profile_key" in
        instagram) if [ "$prefer" -ge 45 ]; then family="VN"; fi ;;
        youtube) if [ "$prefer" -ge 55 ]; then family="VN"; fi ;;
        *) if [ "$prefer" -ge 60 ]; then family="VN"; fi ;;
      esac
    fi

    local variant_roll=$(rand_int 0 99)
    local minor patch
    if [ "$family" = "CapCut" ]; then
      minor=$(rand_int 10 28)
      if [ "$variant_roll" -lt 40 ]; then
        patch=$(rand_int 0 9)
        SOFTWARE_TAG=$(printf "CapCut 12.%d.%d" "$minor" "$patch")
      else
        SOFTWARE_TAG=$(printf "CapCut 12.%d" "$minor")
      fi
    else
      minor=$(rand_int 5 18)
      if [ "$variant_roll" -lt 55 ]; then
        patch=$(rand_int 0 9)
        SOFTWARE_TAG=$(printf "VN 2.%d.%d" "$minor" "$patch")
      else
        SOFTWARE_TAG=$(printf "VN 2.%d" "$minor")
      fi
    fi

    local enc_minor=$(rand_int 2 5)
    ENCODER_TAG=$(printf "Lavf62.%d.100" "$enc_minor")

    if [ "$(rand_int 0 1)" -eq 0 ]; then
      MAJOR_BRAND_TAG="mp42"
    else
      MAJOR_BRAND_TAG="isom"
    fi
    MINOR_VERSION_TAG=$(rand_int 0 512)
    local compat_list=("isommp42" "mp42isom" "iso6mp42")
    local compat_idx
    compat_idx=$(rand_int 0 $(( ${#compat_list[@]} - 1 )))
    COMPAT_BRANDS_TAG="${compat_list[$compat_idx]}"

    local combo_key="${SOFTWARE_TAG}|${ENCODER_TAG}"
    if ! combo_key_seen "$combo_key" || [ "$attempt" -ge 6 ]; then
      mark_combo_key "$combo_key"
      break
    fi
    attempt=$((attempt + 1))
  done
}

REGEN_ITER=0
REGEN_OCCURRED=0
LOW_UNIQUENESS_TRIGGERED=0
MAX_REGEN_ATTEMPTS=2; RUN_COMBO_POS=0

duration_bucket() {
  local value="$1"
  awk -v v="$value" 'BEGIN { printf "%.1f", v }'
}

# REGION AI: uniqueness combo orchestration
# (moved to modules/combo_engine.sh)
generate_copy() {
  local copy_index="$1"
  local regen_tag="${2:-0}"
  local CFPS="" CNOISE="" CMIRROR="" CAUDIO="" CSHIFT="" CBR="" CSOFT="" CLEVEL="" CUR_VF_EXTRA="" CUR_AF_EXTRA="" CUR_COMBO_LABEL="" CUR_COMBO_STRING="" regen_combo=""
  local combo_idx=-1
  combo_engine_autofill
  if [ "$regen_tag" -gt 0 ]; then
    regen_combo=$(next_regen_combo)
    JITTER_RANGE_OVERRIDE=7
    CUR_COMBO_STRING="$regen_combo"
  fi
  if [ -z "$CUR_COMBO_STRING" ] && [ "${#RUN_COMBOS[@]}" -gt 0 ]; then
    combo_idx=$(rand_int 0 $(( ${#RUN_COMBOS[@]} - 1 )))
    CUR_COMBO_STRING="${RUN_COMBOS[$combo_idx]}"
  fi
  local attempt=0
  local combo_preview=""
  local combo_applied=0
  while :; do
    if [ "$combo_applied" -eq 0 ] && [ -n "$CUR_COMBO_STRING" ]; then
      if ! apply_combo_context "$CUR_COMBO_STRING"; then
        echo "[WARN] Combo execution failed: $CUR_COMBO_STRING"
        combo_applied=-1
        attempt=$((attempt + 1))
        continue
      fi
      combo_applied=1
      combo_preview="${CUR_COMBO_LABEL:-$CUR_COMBO_STRING}"
      CUR_VF_EXTRA="$(build_filter "${CUR_VF_EXTRA:-}")"
      CUR_AF_EXTRA="$(build_filter "${CUR_AF_EXTRA:-}")"
      CUR_AF_EXTRA=$(ensure_superequalizer_bounds "${CUR_AF_EXTRA:-}")
      echo "[Strategy] Using combo #${copy_index} → ${combo_preview}"
    fi
    SEED_HEX=$(deterministic_md5 "${SRC}_${copy_index}_соль_${regen_tag}_${attempt}")
    init_rng "$SEED_HEX"
# REGION AI: reset variant descriptor per attempt
    CURRENT_VARIANT_KEY=""
# END REGION AI

    local variant_payload="" variant_ok=0
    local variant_input_basename=""
    local variant_audio_sr="${AUDIO_SR_OPTIONS[0]:-44100}"
    variant_input_basename="$(basename "$SRC")"
    local variant_fs_epoch=""
    if variant_payload=$(python3 "$BASE_DIR/modules/utils/video_tools.py" generate \
      --input "$variant_input_basename" \
      --copy-index "$copy_index" \
      --salt "$RANDOMIZATION_SALT" \
      --profile-br-min "$BR_MIN" \
      --profile-br-max "$BR_MAX" \
      --base-width "$TARGET_W" \
      --base-height "$TARGET_H" \
      --audio-sample-rate "$variant_audio_sr" \
      --format shell 2>&1); then
      while IFS= read -r variant_line; do
        if [[ -z "$variant_line" ]]; then
          continue
        fi
        if [[ "$variant_line" == Adjusted:* ]]; then
          echo "Adjusted: ${variant_line#Adjusted: }"
          continue
        fi
        eval "$variant_line"
      done <<<"$variant_payload"
      variant_ok=1
      variant_fs_epoch="${RAND_FILESYSTEM_EPOCH:-}"
    else
      variant_ok=0
      if [ -n "$variant_payload" ]; then
        echo "⚠️ Video randomization fallback (${variant_payload})" >&2
      else
        echo "⚠️ Video randomization engine unavailable, using legacy parameters" >&2
      fi
    fi
    local -a VARIANT_MICRO_FILTERS=()
    if [ -n "${RAND_MICRO_FILTERS:-}" ]; then
      IFS='|' read -r -a VARIANT_MICRO_FILTERS <<<"${RAND_MICRO_FILTERS}"
    fi

    # параметры видео
    local default_fps
    default_fps=$(select_fps)
    FPS="$default_fps"
    if [ -n "$CFPS" ]; then
      FPS="$CFPS"
    elif [ -n "${RAND_FPS:-}" ]; then
      FPS="${RAND_FPS}"
    fi

    local base_br
    base_br=$(rand_int "$BR_MIN" "$BR_MAX")
    if [ -z "${RAND_BITRATE_KBPS:-}" ]; then
      BR="$base_br"
      if [ "$BR_MIN" -le 4600 ] && [ "$BR_MAX" -ge 3200 ]; then
        local mid_min mid_max
        mid_min=$(( BR_MIN > 3200 ? BR_MIN : 3200 ))
        mid_max=$(( BR_MAX < 4600 ? BR_MAX : 4600 ))
        if [ "$mid_min" -le "$mid_max" ] && [ "$(rand_int 1 100)" -le 72 ]; then
          BR=$(rand_int "$mid_min" "$mid_max")
        fi
      fi
    else
      BR="${RAND_BITRATE_KBPS}"
    fi
    if [ -n "$CBR" ]; then
      BR=$(awk -v b="$BR" -v m="$CBR" 'BEGIN{b+=0;m+=0;if(m<=0)m=1;printf "%.0f",b*m}')
    fi

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
    CLIP_DURATION=$(duration "$CLIP_DURATION" "$clip_duration_fallback" "clip_duration" "copy ${copy_index}")
    TARGET_DURATION="$CLIP_DURATION"
    CLIP_START=$(clip_start "$CLIP_START" "0.000" "clip_start" "copy ${copy_index}")
    if [ -n "$CSHIFT" ]; then
      CLIP_START=$(creative_apply_text_shift "$CLIP_START" "$CSHIFT" "$clip_duration_fallback")
    fi
# END REGION AI

    local NOISE_STRENGTH=0
    NOISE=0
    if [ -n "${RAND_NOISE_STRENGTH:-}" ] && awk -v v="${RAND_NOISE_STRENGTH}" 'BEGIN{exit (v+0>0)?0:1}'; then
      NOISE=1
      NOISE_STRENGTH=$(awk -v v="${RAND_NOISE_STRENGTH}" 'BEGIN{printf "%.0f", v+0}')
    else
      if [ "$(rand_int 1 100)" -le "$NOISE_PROB_PERCENT" ]; then
        NOISE=1
        NOISE_STRENGTH=$(rand_int 1 2)
      fi
      [ -n "$CNOISE" ] && NOISE="$CNOISE"
      if [ "$NOISE" -gt 0 ] && { [ -z "$NOISE_STRENGTH" ] || [ "$NOISE_STRENGTH" -le 0 ]; }; then
        NOISE_STRENGTH=1
      fi
    fi

    if [ -n "${RAND_CROP_MARGIN_W:-}" ] || [ -n "${RAND_CROP_MARGIN_H:-}" ]; then
      CROP_W=$(( ${RAND_CROP_MARGIN_W:-0} ))
      CROP_H=$(( ${RAND_CROP_MARGIN_H:-0} ))
      CROP_X=$(( ${RAND_CROP_OFFSET_X:-0} ))
      CROP_Y=$(( ${RAND_CROP_OFFSET_Y:-0} ))
      [ "$CROP_W" -lt 0 ] && CROP_W=0
      [ "$CROP_H" -lt 0 ] && CROP_H=0
      if [ "$CROP_X" -lt 0 ] || [ "$CROP_X" -gt "$CROP_W" ]; then CROP_X=0; fi
      if [ "$CROP_Y" -lt 0 ] || [ "$CROP_Y" -gt "$CROP_H" ]; then CROP_Y=0; fi
    else
      pick_crop_offsets
      if [ "$TARGET_W" -gt 0 ] && [ "$TARGET_H" -gt 0 ]; then
        local crop_roll=$(rand_int 0 99)
        if [ "$crop_roll" -lt 78 ]; then
          local crop_pct=$(rand_float 0.010 0.020 3)
          local crop_w_side
          crop_w_side=$(awk -v w="$TARGET_W" -v pct="$crop_pct" 'BEGIN{v=int(w*pct/2); if(v<1)v=1; print v}')
          local crop_h_side
          crop_h_side=$(awk -v h="$TARGET_H" -v pct="$crop_pct" 'BEGIN{v=int(h*pct/2); if(v<1)v=1; print v}')
          CROP_W="$crop_w_side"
          CROP_H="$crop_h_side"
          if [ "$CROP_W" -gt 0 ]; then CROP_X=$(rand_int 0 "$CROP_W"); else CROP_X=0; fi
          if [ "$CROP_H" -gt 0 ]; then CROP_Y=$(rand_int 0 "$CROP_H"); else CROP_Y=0; fi
        else
          CROP_W=0
          CROP_H=0
          CROP_X=0
          CROP_Y=0
        fi
      fi
    fi

    # REGION AI: platform audio sample rate selection
    if [ ${#AUDIO_SR_OPTIONS[@]} -gt 0 ]; then
      AUDIO_SR=$(rand_choice AUDIO_SR_OPTIONS)
    fi
    pick_audio_chain
    AFILTER="${AFILTER_CORE:-}"
    if [ -n "${UNICLON_AUDIO_EQ_OVERRIDE:-}" ]; then
      AFILTER_CORE="${UNICLON_AUDIO_EQ_OVERRIDE}"
      AFILTER="${UNICLON_AUDIO_EQ_OVERRIDE}"
    fi
    audio_apply_combo_mode "${CAUDIO:-}" "$TEMPO_FACTOR"
    if [ -z "${AFILTER:-}" ]; then
      if [ -n "${AFILTER_CORE:-}" ]; then
        AFILTER="${AFILTER_CORE}"
      else
        AFILTER="aresample=${AUDIO_SR},atempo=1.0"
      fi
    fi

    AFILTER=$(ensure_superequalizer_bounds "${AFILTER:-}")
    CUR_AF_EXTRA=$(ensure_superequalizer_bounds "${CUR_AF_EXTRA:-}")
    SAFE_AF_CHAIN=$(ensure_superequalizer_bounds "${SAFE_AF_CHAIN:-}")

    if [ -n "${RAND_AUDIO_PITCH:-}" ] || [ -n "${RAND_AUDIO_TEMPO:-}" ]; then
      local tempo_val="${RAND_AUDIO_TEMPO:-1.0}"
      local pitch_val="${RAND_AUDIO_PITCH:-1.0}"
      tempo_val=$(awk -v v="$tempo_val" 'BEGIN{if(v<=0)v=1.0; printf "%.4f", v+0}')
      pitch_val=$(awk -v v="$pitch_val" 'BEGIN{if(v<=0)v=1.0; printf "%.4f", v+0}')
      local variant_audio_chain="asetrate=${AUDIO_SR}*${pitch_val},aresample=${AUDIO_SR},atempo=${tempo_val}"
      CUR_AF_EXTRA=$(compose_af_chain "$variant_audio_chain" "${CUR_AF_EXTRA:-}")
    fi

# REGION AI: enforce variant uniqueness signature
    local crop_signature
    crop_signature=$(printf "%sx%s@%s,%s" "$CROP_W" "$CROP_H" "$CROP_X" "$CROP_Y")
    local duration_signature
    duration_signature=$(awk -v d="$CLIP_DURATION" 'BEGIN{d+=0; printf "%.3f", d}')
    local jitter_signature="$AFILTER"
    if [ -n "$jitter_signature" ]; then
      jitter_signature=$(deterministic_md5 "$jitter_signature")
    fi
    local variant_key="${FPS}|${crop_signature}|${NOISE}|${jitter_signature}|${duration_signature}"
    if variant_key_seen "$variant_key"; then
      if [ "$attempt" -lt 4 ]; then
        attempt=$((attempt + 1))
        continue
      else
        echo "⚠️ Вариант параметров повторяется, сохранён после ${attempt} попыток"
      fi
    fi
    CURRENT_VARIANT_KEY="$variant_key"
# END REGION AI

    MUSIC_VARIANT_TRACK=""
    if [ "$MUSIC_VARIANT" -eq 1 ]; then
      pick_music_variant_track
      if [ -n "$MUSIC_VARIANT_TRACK" ]; then
        AUDIO_PROFILE="${AUDIO_PROFILE}+music"
      fi
    fi

    local audio_br_val
    audio_br_val=$(rand_int 96 160)
    audio_br_val=$(( (audio_br_val / 4) * 4 ))
    if [ "$audio_br_val" -lt 96 ]; then
      audio_br_val=96
    elif [ "$audio_br_val" -gt 160 ]; then
      audio_br_val=160
    fi
    AUDIO_BR="${audio_br_val}k"

    creative_pick_mirror "$ENABLE_MIRROR" "${CMIRROR:-}"
    local MIRROR_ACTIVE="${MIRROR_ACTIVE}"
    local MIRROR_FILTER="${MIRROR_FILTER}"
    local MIRROR_DESC="${MIRROR_DESC}"

    creative_pick_lut "$ENABLE_LUT" LUT_FILES
    local LUT_ACTIVE="${LUT_ACTIVE}"
    local LUT_FILTER="${LUT_FILTER}"
    local LUT_DESC="${LUT_DESC}"

    creative_pick_intro "$ENABLE_INTRO" INTRO_CLIPS
    local INTRO_ACTIVE="${INTRO_ACTIVE}"
    local INTRO_SOURCE="${INTRO_SOURCE}"
    local INTRO_DURATION="${INTRO_DURATION}"
    local INTRO_DESC="${INTRO_DESC}"

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

  SEED="${RAND_SEED:-$SEED_HEX}"
  LAST_COMBOS+=("$combo_key")
  COMBO_HISTORY="${COMBO_HISTORY}${combo_key} "

  local RATE_PAD=0
  if [ -n "${RAND_MAXRATE_KBPS:-}" ]; then
    MAXRATE="${RAND_MAXRATE_KBPS}"
  else
    RATE_PAD=$(rand_int 250 650)
    MAXRATE=$((BR + RATE_PAD))
  fi
  if [ -n "${RAND_BUFSIZE_KBPS:-}" ]; then
    BUFSIZE="${RAND_BUFSIZE_KBPS}"
  else
    if [ "$RATE_PAD" -eq 0 ]; then
      RATE_PAD=$(rand_int 250 650)
    fi
    BUFSIZE=$((BR * 2 + RATE_PAD * 2))
  fi

  if [ "$variant_ok" -eq 1 ] && [ -n "${RAND_SOFTWARE:-}" ] && [ -n "${RAND_ENCODER:-}" ]; then
    SOFTWARE_TAG="${RAND_SOFTWARE}"
    ENCODER_TAG="${RAND_ENCODER}"
    if [ "$(rand_int 0 1)" -eq 0 ]; then
      MAJOR_BRAND_TAG="mp42"
    else
      MAJOR_BRAND_TAG="isom"
    fi
    MINOR_VERSION_TAG=$(rand_int 0 512)
    local compat_list=("isommp42" "mp42isom" "iso6mp42")
    local compat_idx
    compat_idx=$(rand_int 0 $(( ${#compat_list[@]} - 1 )))
    COMPAT_BRANDS_TAG="${compat_list[$compat_idx]}"
  else
    pick_software_encoder "$PROFILE_VALUE" "$SEED_HEX"; CSOFT=""
  fi
  CSOFT=""

  if [ -n "${RAND_CREATION_TIME:-}" ]; then
    CREATION_TIME="${RAND_CREATION_TIME}"
    CREATION_TIME_EXIF="${RAND_CREATION_TIME_EXIF:-$RAND_CREATION_TIME}"
  else
    CREATION_TIME=$(generate_iso_timestamp)
    CREATION_TIME=$(jitter_iso_timestamp "$CREATION_TIME")
    CREATION_TIME_EXIF="$CREATION_TIME"
  fi
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
  TITLE="$(rand_title) $(rand_int 10 99)"
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
      youtube)
        qt_choice="Apple|iPhone 14|iPhone15,2"
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

  STRETCH_FACTOR=$(awk -v v="${STRETCH_FACTOR:-}" 'BEGIN{
    if (v == "" || v+0 <= 0) { printf "%.6g", 1.0 } else { printf "%.6g", v+0 }
  }')
  local SCALE_W="$TARGET_W"
  local SCALE_H="$TARGET_H"
  if [ -n "${RAND_SCALE_WIDTH:-}" ]; then
    SCALE_W="${RAND_SCALE_WIDTH}"
  fi
  if [ -n "${RAND_SCALE_HEIGHT:-}" ]; then
    SCALE_H="${RAND_SCALE_HEIGHT}"
  fi
  local brightness_val contrast_val saturation_val
  brightness_val=$(awk -v v="${RAND_BRIGHTNESS:-0.005}" 'BEGIN{printf "%.4f", v+0}')
  contrast_val=$(awk -v v="${RAND_CONTRAST:-1.010}" 'BEGIN{printf "%.4f", v+0}')
  saturation_val=$(awk -v v="${RAND_SATURATION:-1.010}" 'BEGIN{printf "%.4f", v+0}')
  VF="setpts=${STRETCH_FACTOR}*PTS,scale=${SCALE_W}:${SCALE_H}:flags=lanczos,setsar=1"  # fix: корректный синтаксис setpts
  VF="${VF},eq=brightness=${brightness_val}:contrast=${contrast_val}:saturation=${saturation_val}"
  if [ "$NOISE" -eq 1 ] && [ "${NOISE_STRENGTH:-0}" -gt 0 ]; then
    VF="${VF},noise=alls=${NOISE_STRENGTH}:allf=t"
  elif [ "$NOISE" -eq 1 ]; then
    VF="${VF},noise=alls=1:allf=t"
  fi
  local micro_filter
  for micro_filter in "${VARIANT_MICRO_FILTERS[@]}"; do
    [ -n "$micro_filter" ] && VF="${VF},${micro_filter}"
  done
  if [ "$CROP_TOTAL_W" -gt 0 ] || [ "$CROP_TOTAL_H" -gt 0 ]; then
    CROP_WIDTH=$((TARGET_W - CROP_TOTAL_W))
    CROP_HEIGHT=$((TARGET_H - CROP_TOTAL_H))
    if [ "$CROP_WIDTH" -lt 16 ]; then CROP_WIDTH=$((TARGET_W - CROP_W)); fi
    if [ "$CROP_HEIGHT" -lt 16 ]; then CROP_HEIGHT=$((TARGET_H - CROP_H)); fi
    if [ "$CROP_WIDTH" -lt 16 ]; then CROP_WIDTH=$TARGET_W; fi
    if [ "$CROP_HEIGHT" -lt 16 ]; then CROP_HEIGHT=$TARGET_H; fi
    VF="${VF},crop=${CROP_WIDTH}:${CROP_HEIGHT}:${CROP_X}:${CROP_Y}"
  fi
  local extras_chain=""
  if [ "$MIRROR_ACTIVE" -eq 1 ]; then
    extras_chain=$(compose_vf_chain "$extras_chain" "$MIRROR_FILTER")
  fi
  if [ "$LUT_ACTIVE" -eq 1 ] && [ -n "$LUT_FILTER" ]; then
    extras_chain=$(compose_vf_chain "$extras_chain" "$LUT_FILTER")
  fi
  extras_chain=$(compose_vf_chain "$extras_chain" "$CUR_VF_EXTRA")
  VF=$(compose_vf_chain "$VF" "$extras_chain")
  if [ -n "${RAND_LUT_DESCRIPTOR:-}" ]; then
    if [ -n "$LUT_DESC" ]; then
      LUT_DESC="${LUT_DESC};${RAND_LUT_DESCRIPTOR}"
    else
      LUT_DESC="${RAND_LUT_DESCRIPTOR}"
    fi
  fi
  local pad_offset_x="${RAND_PAD_OFFSET_X:-0}"
  local pad_offset_y="${RAND_PAD_OFFSET_Y:-0}"
  local pad_x_expr="(ow-iw)/2"
  local pad_y_expr="(oh-ih)/2"
  if [ "${pad_offset_x}" != "0" ]; then
    pad_x_expr="${pad_x_expr}+${pad_offset_x}"
  fi
  if [ "${pad_offset_y}" != "0" ]; then
    pad_y_expr="${pad_y_expr}+${pad_offset_y}"
  fi
  VF="${VF},pad=${TARGET_W}:${TARGET_H}:${pad_x_expr}:${pad_y_expr}:black"
  PAD_X="$pad_offset_x"
  PAD_Y="$pad_offset_y"
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

  local CODEC_LEVEL="4.0"
  if [ "$FPS" -ge 60 ]; then
    CODEC_LEVEL="4.2"
  fi
  [ -n "$CLEVEL" ] && CODEC_LEVEL="$CLEVEL"

  local vf_payload
  vf_payload=$(ensure_vf_format "$VF")
  local af_payload
  af_payload=$(compose_af_chain "$AFILTER" "$CUR_AF_EXTRA")
  af_payload=$(ensure_superequalizer_bounds "$af_payload")
# REGION AI: inject safe uniqueness chain at tail
  if [ -n "${SAFE_AF_CHAIN:-}" ]; then
    af_payload=$(compose_af_chain "$SAFE_AF_CHAIN" "$af_payload")
  fi
# END REGION AI

  # REGION AI: primary ffmpeg command with stable stream mapping
  local audio_input_index=0 audio_stream_present=0
  AUDIO_CODEC="none"
  local audio_info=""
  if audio_info=$(ffmpeg_audio_stream_info "$SRC"); then
    audio_stream_present=1
  fi
  if [ -n "$audio_info" ]; then
    AUDIO_CODEC="$audio_info"
  fi
  AUDIO_CODEC=${AUDIO_CODEC:-none}
  AUDIO_CHAIN=$(audio_guard_chain "$AUDIO_CODEC" "$af_payload")
  if [ -z "${AUDIO_FILTER:-}" ]; then
    AUDIO_FILTER="anull"
  fi
  local combined_audio_filters="$AUDIO_CHAIN"
  if [ -n "$AUDIO_FILTER" ]; then
    combined_audio_filters="${combined_audio_filters:+$combined_audio_filters,}$AUDIO_FILTER"
  fi
  combined_audio_filters=$(sanitize_audio_filters "$combined_audio_filters")
  combined_audio_filters=$(ensure_superequalizer_bounds "$combined_audio_filters")
  FFMPEG_ARGS=(
    -y -hide_banner -loglevel warning -ignore_unknown
    -analyzeduration 200M -probesize 200M
    -ss "$CLIP_START" -i "$SRC"
  )
  if [ "$MUSIC_VARIANT" -eq 1 ] && [ -n "$MUSIC_VARIANT_TRACK" ]; then
    FFMPEG_ARGS+=(-analyzeduration 200M -probesize 200M -ss "$CLIP_START" -i "$MUSIC_VARIANT_TRACK")
    audio_input_index=1
  elif [ "$audio_stream_present" -eq 0 ]; then
    FFMPEG_ARGS+=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
    audio_input_index=1
  fi
  FFMPEG_ARGS+=(-map 0:v:0)
  if [ "$MUSIC_VARIANT" -eq 1 ] && [ -n "$MUSIC_VARIANT_TRACK" ]; then
    FFMPEG_ARGS+=(-map "${audio_input_index}:a:0?" -shortest)
  elif [ "$audio_stream_present" -eq 1 ]; then
    FFMPEG_ARGS+=(-map "0:a:0?")
  else
    FFMPEG_ARGS+=(-map "${audio_input_index}:a:0" -shortest)
  fi
  FFMPEG_ARGS+=(-t "$CLIP_DURATION" -c:v libx264 -preset slow -profile:v "$VIDEO_PROFILE" -level "$CODEC_LEVEL" -crf "$CRF"
    -r "$FPS" -b:v "${BR}k" -maxrate "${MAXRATE}k" -bufsize "${BUFSIZE}k"
    -vf "$vf_payload"
    -c:a aac -b:a "$AUDIO_BR" -ar "$AUDIO_SR" -ac 2 -af "$combined_audio_filters"
    -movflags +faststart
    -map_metadata -1
    -metadata location=""
    -metadata handler_name=""
    -metadata com.apple.quicktime.location.ISO6709=""
    -metadata project=""
    -metadata dir=""
    -metadata creation_app=""
    -metadata major_brand="$MAJOR_BRAND_TAG"
    -metadata minor_version="$MINOR_VERSION_TAG"
    -metadata compatible_brands="$COMPAT_BRANDS_TAG"
    -metadata encoder="$ENCODER_TAG"
    -metadata software="$SOFTWARE_TAG"
    -metadata creation_time="$CREATION_TIME"
    -metadata title="$TITLE"
    -metadata description="$DESCRIPTION"
    -metadata comment="$UID_TAG"
    "$ENCODE_TARGET")
  # END REGION AI

  if [ "$DEBUG" -eq 1 ]; then
    echo "DEBUG copy=$copy_index seed=$SEED fps=$FPS br=${BR}k crf=$CRF maxrate=${MAXRATE}k bufsize=${BUFSIZE}k clip_start=${CLIP_START}s target_duration=$TARGET_DURATION stretch=$STRETCH_FACTOR audio=$AUDIO_PROFILE af='$af_payload' music_track=${MUSIC_VARIANT_TRACK:-none} noise=$NOISE crop=${CROP_W}x${CROP_H}@${CROP_X},${CROP_Y} pad=${PAD_X},${PAD_Y} quality=$QUALITY profile=${PROFILE_VALUE} mirror=${MIRROR_DESC} lut=${LUT_DESC} intro=${INTRO_DESC}"
  fi

  echo "▶️ [$copy_index/$COUNT] $SRC → $OUT | fps=$FPS br=${BR}k noise=$NOISE crop=${CROP_W}x${CROP_H} duration=${TARGET_DURATION}s audio=${AUDIO_PROFILE} profile=${PROFILE_VALUE} mirror=${MIRROR_DESC} lut=${LUT_DESC} intro=${INTRO_DESC}"

  local ffmpeg_cmd_preview
  ffmpeg_cmd_preview=$(ffmpeg_command_preview "${FFMPEG_ARGS[@]}")
  ffmpeg_cmd_preview=${ffmpeg_cmd_preview% }
  echo "ℹ️ clip_start=$CLIP_START duration=$CLIP_DURATION"
  echo "ℹ️ ffmpeg command: $ffmpeg_cmd_preview"

  # REGION AI: safe ffmpeg execution via bash wrapper
  local FFMPEG_CMD="$ffmpeg_cmd_preview"
  bash -c "$FFMPEG_CMD"
  if [[ $? -ne 0 ]]; then
    log_error "FFmpeg command failed: $FFMPEG_CMD"
    exit 2
  fi
  # END REGION AI

  if [ "$INTRO_ACTIVE" -eq 1 ] && [ -n "$INTRO_SOURCE" ] && [ -n "$INTRO_OUTPUT_PATH" ]; then
    # REGION AI: intro render with resilient audio mapping
    local intro_audio_present=0
    if ffmpeg_audio_stream_info "$INTRO_SOURCE" >/dev/null 2>&1; then
      intro_audio_present=1
    fi
    local intro_args=(
      -y -hide_banner -loglevel warning -ignore_unknown
      -analyzeduration 200M -probesize 200M
      -t "$INTRO_DURATION" -i "$INTRO_SOURCE"
    )
    if [ "$intro_audio_present" -eq 0 ]; then
      intro_args+=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 -map 0:v:0 -map "1:a:0")
    else
      intro_args+=(-map 0:v:0 -map "0:a:0?")
    fi

    intro_args+=(
      -vf "scale=${TARGET_W}:${TARGET_H}:flags=lanczos,setsar=1,format=yuv420p"
      -r "$FPS" -c:v libx264 -preset slow -profile:v "$VIDEO_PROFILE" -level "$VIDEO_LEVEL" -crf "$CRF"
      -c:a aac -b:a "$AUDIO_BR" -ar "$AUDIO_SR" -ac 2
      -af "aresample=${AUDIO_SR},apad,atrim=0:${INTRO_DURATION}" -movflags +faststart "$INTRO_OUTPUT_PATH"
    )

    ffmpeg_exec "${intro_args[@]}"
    # END REGION AI
    CONCAT_LIST_FILE=$(mktemp "${OUTPUT_DIR}/.intro_concat_XXXXXX.txt")
    {
      printf "file '%s'\n" "$INTRO_OUTPUT_PATH"
      printf "file '%s'\n" "$ENCODE_TARGET"
    } > "$CONCAT_LIST_FILE"
    ffmpeg_exec -y -hide_banner -loglevel warning -f concat -safe 0 -i "$CONCAT_LIST_FILE" -c copy -movflags +faststart "$FINAL_OUT"
    rm -f "$CONCAT_LIST_FILE" "$INTRO_OUTPUT_PATH"
    rm -f "$ENCODE_TARGET"
    OUT="$FINAL_OUT"
  else
    OUT="$ENCODE_TARGET"
  fi

  # REGION AI: exif randomization bindings
  RND_DATE="$CREATION_TIME_EXIF"
  EXIF_CMD=(
    exiftool
    -overwrite_original
    -GPS:all=
    -Location:all=
    -SerialNumber=
    -Software="$SOFTWARE_TAG"
    -Encoder="$ENCODER_TAG"
    -CreateDate="$RND_DATE"
    -ModifyDate="$RND_DATE"
    -QuickTime:CreateDate="$RND_DATE"
    -QuickTime:ModifyDate="$RND_DATE"
  )
  # END REGION AI
  if [ "$QT_META" -eq 1 ]; then
    if [ "$DEVICE_INFO" -eq 1 ]; then
      if [ -n "$QT_MAKE" ]; then
        EXIF_CMD+=(-Make="$QT_MAKE" -QuickTime:Make="$QT_MAKE")
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
      if [ -n "$QT_MODEL" ]; then
        EXIF_CMD+=(-QuickTime:Model="$QT_MODEL")
      fi
    fi
    if [ -n "$QT_SOFTWARE" ]; then
      EXIF_CMD+=(-Software="$QT_SOFTWARE")
    fi
  fi
  EXIF_CMD+=("$OUT")
  "${EXIF_CMD[@]}" >/dev/null

  if [ -n "$variant_fs_epoch" ]; then
    if ! python3 "$BASE_DIR/modules/utils/video_tools.py" touch --file "$OUT" --epoch "$variant_fs_epoch" >/dev/null 2>&1; then
      touch_randomize_mtime "$OUT"
    fi
  else
    touch_randomize_mtime "$OUT"
  fi
  FILE_NAME="$(basename "$OUT")"
  local MEDIA_DURATION_RAW=""
  local MEDIA_DURATION_SEC=""
  MEDIA_DURATION_RAW=$(ffmpeg_media_duration_raw "$OUT")
  MEDIA_DURATION_SEC=$(ffmpeg_media_duration_seconds "$OUT" 2>/dev/null || true)
  local PREVIEW_NAME=""
  local PREVIEW_PATH="${PREVIEW_DIR}/${FILE_STEM}.png"
  if [ -n "$MEDIA_DURATION_RAW" ] && [ "$MEDIA_DURATION_RAW" != "N/A" ]; then
    if [ -z "$MEDIA_DURATION_SEC" ]; then
      echo "⚠️ Не удалось преобразовать длительность $FILE_NAME (${MEDIA_DURATION_RAW}) для проверки превью"
    fi
  else
    echo "⚠️ Не удалось определить длительность $FILE_NAME перед генерацией превью"
    MEDIA_DURATION_RAW=""
    MEDIA_DURATION_SEC=""
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

  if ffmpeg_exec -y -hide_banner -loglevel error -ss "$preview_seek_value" -i "$OUT" -vframes 1 "$PREVIEW_PATH"; then
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
  DURATION_RAW="$MEDIA_DURATION_RAW"
  if [ -z "$DURATION_RAW" ]; then
    DURATION_RAW=$(ffprobe_exec -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT")
  fi
  DURATION=$(awk -v d="$DURATION_RAW" 'BEGIN{if(d==""||d=="N/A") printf "0"; else printf "%.3f", d}')
  SIZE_BYTES=$(file_size_bytes "$OUT")
  SIZE_KB=$(awk -v s="$SIZE_BYTES" 'BEGIN{if(s==""||s==0) printf "0"; else printf "%.0f", s/1024}')
  RUN_FILES+=("$FILE_NAME")
  RUN_FPS+=("$FPS")
  RUN_DURATIONS+=("$DURATION")
  RUN_SIZES+=("$SIZE_KB")
  RUN_ENCODERS+=("$ENCODER_TAG")
  RUN_SOFTWARES+=("$SOFTWARE_TAG")
  RUN_CREATION_TIMES+=("$CREATION_TIME")
  RUN_SEEDS+=("$SEED")
  RUN_TARGET_DURS+=("$TARGET_DURATION")
  RUN_TARGET_BRS+=("$BR")
  RUN_COMBO_HISTORY+=("$combo_key")
  RUN_PROFILES+=("$PROFILE_VALUE")
  RUN_QUALITIES+=("$QUALITY")
  RUN_QT_MAKES+=("$QT_MAKE")
  RUN_QT_MODELS+=("$QT_MODEL")

  RUN_QT_SOFTWARES+=("$QT_SOFTWARE")
  RUN_CREATIVE_MIRROR+=("$MIRROR_DESC")
  RUN_CREATIVE_INTRO+=("$INTRO_DESC")
  RUN_CREATIVE_LUT+=("$LUT_DESC")
  RUN_PREVIEWS+=("$PREVIEW_NAME")
  RUN_FS_TIMESTAMPS+=("${variant_fs_epoch:-}")
# REGION AI: persist variant signature state
  if [ -n "$CURRENT_VARIANT_KEY" ]; then
    mark_variant_key "$CURRENT_VARIANT_KEY"
    RUN_VARIANT_KEYS+=("$CURRENT_VARIANT_KEY")
  else
    RUN_VARIANT_KEYS+=("")
  fi
# END REGION AI

  # REGION AI: similarity fallback with reinforced effects
  local base_vf="$VF" base_af="$AFILTER" base_af_extra="${CUR_AF_EXTRA:-}"
  local metrics metrics_ssim metrics_psnr metrics_phash metrics_bitrate metrics_delta metrics_uniq
  local fallback_attempts=0
  local max_uniqueness_retry_raw="${MAX_RETRY:-$MAX_REGEN_ATTEMPTS}"
  local max_uniqueness_retry
  if [[ "$max_uniqueness_retry_raw" =~ ^[0-9]+$ ]]; then
    max_uniqueness_retry="$max_uniqueness_retry_raw"
  else
    max_uniqueness_retry="$MAX_REGEN_ATTEMPTS"
  fi
  if (( max_uniqueness_retry < 1 )); then
    max_uniqueness_retry=1
  fi
  local total_copies_context=${#RUN_FILES[@]}
  local uniqueness_guard=0
  if (( total_copies_context < 2 )); then
    uniqueness_guard=1
  fi
  local uniqueness_verdict="OK" manager_output="" reason_line="" fallback_reason_entry=""
  local combo_used_label="${combo_preview:-${CUR_COMBO_STRING:-base}}"
  while :; do
    metrics=$(metrics_compute_copy_metrics "$SRC" "$OUT"); IFS='|' read -r metrics_ssim metrics_psnr metrics_phash metrics_bitrate metrics_delta metrics_uniq <<< "$metrics"
    if (( uniqueness_guard )); then
      echo "[WARN] Uniqueness low but accepted (first copies)."
      fallback_reason_entry="first_copies"
      uniqueness_verdict="OK"
      break
    fi
    manager_output=$("$BASE_DIR/modules/fallback_manager.sh" "$metrics_ssim" "$metrics_phash" "$metrics_delta")
    printf '%s\n' "$manager_output"
    uniqueness_verdict=$(printf '%s' "$manager_output" | head -n1)
    reason_line=$(printf '%s' "$manager_output" | sed -n '2p')
    if [ "$uniqueness_verdict" = "RETRY" ]; then
      if ! fallback_soft_retry_guard "$copy_index" "$fallback_attempts" "$reason_line"; then
        echo "[INFO] Copy $copy_index skipped after low uniqueness retries"
        fallback_reason_entry="soft_retry_skipped"
        uniqueness_verdict="SKIP"
        break
      fi
      fallback_attempts=$((fallback_attempts + 1))
      if [ "$fallback_attempts" -ge "$max_uniqueness_retry" ]; then
        echo "[WARN] Max regeneration attempts reached for copy $copy_index — accepting result."
        uniqueness_verdict="ACCEPT_WARN"
        fallback_reason_entry="${reason_line:-max_regen_reached}"
        break
      fi
      local combo_payload="" combo_vf="" combo_af=""
      combo_payload=$(next_combo)
      if [ -z "$combo_payload" ]; then
        uniqueness_verdict="ACCEPT_WARN"
        fallback_reason_entry="$reason_line"
        break
      fi
      echo "[Fallback] Copy $copy_index too similar — regenerating with $combo_payload"
      combo_used_label="$combo_payload"
      local combo_filters=""
      if combo_filters=$(combo_extract_filters "$combo_payload"); then
        IFS=$'\t' read -r combo_vf combo_af <<<"$combo_filters"
      else
        combo_vf=""
        combo_af=""
      fi
      combo_vf="$(build_filter "$combo_vf")"
      combo_af="$(build_filter "$combo_af")"
      local fallback_vf_extra="" fallback_af_extra="$base_af_extra"
      [ -n "$combo_vf" ] && fallback_vf_extra="${fallback_vf_extra:+$fallback_vf_extra,}$combo_vf"
      [ -n "$combo_af" ] && fallback_af_extra="${fallback_af_extra:+$fallback_af_extra,}$combo_af"
      local fallback_vf_chain
      fallback_vf_chain=$(creative_vignette_chain "$base_vf" "$fallback_vf_extra")
      fallback_vf_chain=$(ensure_vf_format "$fallback_vf_chain")
      local fallback_af_chain
      fallback_af_chain=$(compose_af_chain "$base_af" "$fallback_af_extra")
      fallback_af_chain=$(ensure_superequalizer_bounds "$fallback_af_chain")
      fallback_af_chain=$(sanitize_audio_filters "$fallback_af_chain")
      ffmpeg_exec -y -hide_banner -loglevel warning -ss "$CLIP_START" -i "$SRC" \
        -t "$CLIP_DURATION" -c:v libx264 -preset medium -crf 24 \
        -vf "$fallback_vf_chain" \
        -c:a aac -b:a "$AUDIO_BR" -ar "$AUDIO_SR" -ac 2 -af "$fallback_af_chain" -movflags +faststart "$OUT"
      continue
    fi
    if [ "$uniqueness_verdict" = "ACCEPT_WARN" ] && [ -z "$fallback_reason_entry" ]; then
      fallback_reason_entry="$reason_line"
    fi
    break
  done
  fallback_soft_register_result "$copy_index" "$uniqueness_verdict"
  local uniqueness_attempts=$((fallback_attempts + 1))
  RUN_FALLBACK_REASON+=("$fallback_reason_entry")
  RUN_COMBO_USED+=("$combo_used_label")
  RUN_ATTEMPTS+=("$uniqueness_attempts")
  if [ "$uniqueness_verdict" = "ACCEPT_WARN" ]; then
    echo "⚠️ Copy $copy_index accepted with low uniqueness after $uniqueness_attempts attempts"
  fi
  # END REGION AI

  RUN_SSIM+=("$metrics_ssim")
  RUN_PSNR+=("$metrics_psnr")
  RUN_PHASH+=("$metrics_phash")
  RUN_UNIQ+=("$metrics_uniq")
  RUN_BITRATES+=("$metrics_bitrate")
  local trust_score_value="0.00"
  if [ -n "$metrics_ssim" ] && [ -n "$metrics_phash" ]; then
    trust_score_value=$(python3 "$BASE_DIR/modules/utils/video_tools.py" score --ssim "$metrics_ssim" --phash "$metrics_phash" 2>/dev/null || printf '0.00')
  fi
  RUN_TRUST_SCORE+=("$trust_score_value")

  echo "✅ done: $OUT"
  printf '[Uniclon v1.7] Saved as: %s  (seed=%s, software=%s)\n' \
    "$OUT_NAME" "${CURRENT_SEED_PRINT:-0.000}" "$SOFTWARE_TAG"
}

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
