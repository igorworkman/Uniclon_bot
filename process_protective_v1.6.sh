#!/bin/bash
# process_protective_v1.6.sh (macOS совместимая версия)
# Делает N уникальных копий из одного видео, сохраняет в "Новая папка/"
set -euo pipefail
IFS=$'\n\t'

DEBUG=0
MUSIC_VARIANT=0
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      ;;
    --music-variant)
      MUSIC_VARIANT=1
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done
set -- "${POSITIONAL[@]}"

OUTPUT_DIR="Новая папка"
MANIFEST="manifest.csv"
MANIFEST_PATH="${OUTPUT_DIR}/${MANIFEST}"
TARGET_W=1080
TARGET_H=1920
AUDIO_BR="128k"
BR_MIN=2800
BR_MAX=5000
FPS_BASE=(24 25 30 50 59.94 60)
FPS_RARE=(23.976 27 29.97 48 53.95 57)
NOISE_PROB_PERCENT=30
CROP_MAX_PX=6
AUDIO_TWEAK_PROB_PERCENT=50
MUSIC_VARIANT_TRACKS=()
MUSIC_VARIANT_TRACK=""

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

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "filename,bitrate,fps,duration,size_kb,encoder,software,creation_time,seed,target_duration,target_bitrate" > "$MANIFEST_PATH"
else
  if ! head -n1 "$MANIFEST_PATH" | grep -q "target_duration"; then
    TMP_MANIFEST=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},target_duration,target_bitrate"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},," 
      done
    } < "$MANIFEST_PATH" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_PATH"
    echo "ℹ️ manifest обновлён: добавлены колонки target_duration и target_bitrate"
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
  local A="$1" B="$2" span=$((B - A + 1)) raw
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

iso_to_components() {
  local iso="$1"
  local date_part="${iso%%T*}"
  local time_part="${iso#*T}"
  time_part="${time_part%Z}"
  local y="${date_part%%-*}"
  local rest="${date_part#*-}"
  local m="${rest%%-*}"
  local d="${rest#*-}"
  local hh="${time_part%%:*}"
  rest="${time_part#*:}"
  local mm="${rest%%:*}"
  local ss="${rest#*:}"
  printf "%s %s %s %s %s %s\n" "$y" "$m" "$d" "$hh" "$mm" "$ss"
}

generate_media_name() {
  local iso="$1"
  local y m d hh mm ss
  local IFS=' '
  read -r y m d hh mm ss < <(iso_to_components "$iso")
  local ts_for_name=$(printf "%s%s%s_%s%s%s" "$y" "$m" "$d" "$hh" "$mm" "$ss")
  local roll=$(rand_int 0 99)
  if [ "$roll" -lt 25 ]; then
    local img_suffix=$(rand_int 6000 6999)
    printf "IMG_%d MOV\n" "$img_suffix"
  else
    printf "VID_%s mp4\n" "$ts_for_name"
  fi
}

iso_to_touch_ts() {
  local iso="$1"
  local y m d hh mm ss
  local IFS=' '
  read -r y m d hh mm ss < <(iso_to_components "$iso")
  printf "%s%s%s%s%s.%s\n" "$y" "$m" "$d" "$hh" "$mm" "$ss"
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

select_fps() {
  if [ "$(rand_int 1 100)" -le 22 ]; then
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
  local filters=("aresample=44100")
  if [ "$roll" -le "$AUDIO_TWEAK_PROB_PERCENT" ]; then
    AUDIO_PROFILE="asetrate"
    local factor=$(rand_float 0.985 1.015 6)
    filters=("asetrate=44100*${factor}" "aresample=44100")
  elif [ "$roll" -ge 85 ]; then
    AUDIO_PROFILE="anull"
    filters=("anull" "aresample=44100")
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

COMBO_HISTORY=""
declare -a LAST_COMBOS=()

for ((i=1;i<=COUNT;i++)); do
  attempt=0
  while :; do
    SEED_HEX=$(deterministic_md5 "${SRC}_${i}_соль_${attempt}")
    init_rng "$SEED_HEX"

    # параметры видео
    FPS=$(select_fps)

    BR=$(rand_int "$BR_MIN" "$BR_MAX")

    compute_duration_profile

    NOISE=0
    if [ "$(rand_int 1 100)" -le "$NOISE_PROB_PERCENT" ]; then
      NOISE=1
    fi

    pick_crop_offsets

    pick_audio_chain

    local jitter_filters=()
    if (( RANDOM % 3 == 0 )); then
      jitter_filters=("asetrate=44100*1.$((RANDOM%6))" "aresample=44100")
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
      echo "⚠️ Не удалось подобрать уникальные параметры для копии $i, используем последние"
      break
    fi
  done

  SEED="$SEED_HEX"
  LAST_COMBOS+=("$combo_key")
  COMBO_HISTORY="${COMBO_HISTORY}${combo_key} "

  RATE_PAD=$(rand_int 250 650)
  MAXRATE=$((BR + RATE_PAD))
  BUFSIZE=$((BR * 2 + RATE_PAD * 2))

  ENC_MINOR=$(rand_int 2 5)
  ENC_PATCH=$(rand_int 0 255)
  ENCODER_TAG=$(printf "Lavf62.%d.%03d" "$ENC_MINOR" "$ENC_PATCH")

  if [ "$(rand_int 0 1)" -eq 0 ]; then
    SOFTWARE_TAG="CapCut 12.$(rand_int 1 9)"
  else
    SOFTWARE_TAG="VN 2.$(rand_int 1 9)"
  fi

  CREATION_TIME=$(generate_iso_timestamp)
  CREATION_TIME_EXIF=$(echo "$CREATION_TIME" | sed 's/T/ /; s/Z$//; s/-/:/g')
  read FILE_STEM FILE_EXT <<<"$(generate_media_name "$CREATION_TIME")"
  OUT="${OUTPUT_DIR}/${FILE_STEM}.${FILE_EXT}"
  while [ -e "$OUT" ]; do
    CREATION_TIME=$(generate_iso_timestamp)
    CREATION_TIME_EXIF=$(echo "$CREATION_TIME" | sed 's/T/ /; s/Z$//; s/-/:/g')
    read FILE_STEM FILE_EXT <<<"$(generate_media_name "$CREATION_TIME")"
    OUT="${OUTPUT_DIR}/${FILE_STEM}.${FILE_EXT}"
  done
  TITLE="$FILE_STEM"
  DESCRIPTION="$(rand_description)"

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
  VF="${VF},drawtext=text='${UID_TAG}':fontcolor=white@0.08:fontsize=16:x=10:y=H-30"

  FFMPEG_CMD=(ffmpeg -y -hide_banner -loglevel warning -i "$SRC")
  if [ "$MUSIC_VARIANT" -eq 1 ] && [ -n "$MUSIC_VARIANT_TRACK" ]; then
    FFMPEG_CMD+=(-i "$MUSIC_VARIANT_TRACK" -map 0:v:0 -map 1:a:0 -shortest)
  fi
  FFMPEG_CMD+=(-c:v libx264 -preset slow -profile:v high -level 4.0
    -r "$FPS" -b:v "${BR}k" -maxrate "${MAXRATE}k" -bufsize "${BUFSIZE}k"
    -vf "$VF"
    -c:a aac -b:a "$AUDIO_BR" -af "$AFILTER"
    -movflags +faststart
    -metadata encoder="$ENCODER_TAG"
    -metadata software="$SOFTWARE_TAG"
    -metadata creation_time="$CREATION_TIME"
    -metadata title="$TITLE"
    -metadata description="$DESCRIPTION"
    -metadata comment="$UID_TAG"
    "$OUT")

  if [ "$DEBUG" -eq 1 ]; then
    echo "DEBUG copy=$i seed=$SEED fps=$FPS br=${BR}k maxrate=${MAXRATE}k bufsize=${BUFSIZE}k target_duration=$TARGET_DURATION stretch=$STRETCH_FACTOR audio=$AUDIO_PROFILE af='$AFILTER' music_track=${MUSIC_VARIANT_TRACK:-none} noise=$NOISE crop=${CROP_W}x${CROP_H}@${CROP_X},${CROP_Y} pad=${PAD_X},${PAD_Y}"
  fi

  echo "▶️ [$i/$COUNT] $SRC → $OUT | fps=$FPS br=${BR}k noise=$NOISE crop=${CROP_W}x${CROP_H} duration=${TARGET_DURATION}s audio=${AUDIO_PROFILE}"

  "${FFMPEG_CMD[@]}"

  exiftool -overwrite_original \
    -GPS:all= -Location:all= -SerialNumber= \
    -Software="$SOFTWARE_TAG" \
    -CreateDate="$CREATION_TIME_EXIF" -ModifyDate="$CREATION_TIME_EXIF" \
    -QuickTime:CreateDate="$CREATION_TIME_EXIF" -QuickTime:ModifyDate="$CREATION_TIME_EXIF" \
    "$OUT" >/dev/null

  FAKE_TS=$(iso_to_touch_ts "$CREATION_TIME")
  touch -t "$FAKE_TS" "$OUT"
  FILE_NAME="$(basename "$OUT")"
  BITRATE_RAW=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$OUT")
  BITRATE=$(awk -v b="$BITRATE_RAW" 'BEGIN{if(b==""||b=="N/A") printf "0"; else printf "%.0f", b/1000}')
  DURATION_RAW=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT")
  DURATION=$(awk -v d="$DURATION_RAW" 'BEGIN{if(d==""||d=="N/A") printf "0"; else printf "%.3f", d}')
  SIZE_BYTES=$(file_size_bytes "$OUT")
  SIZE_KB=$(awk -v s="$SIZE_BYTES" 'BEGIN{if(s==""||s==0) printf "0"; else printf "%.0f", s/1024}')
  echo "$FILE_NAME,$BITRATE,$FPS,$DURATION,$SIZE_KB,$ENCODER_TAG,$SOFTWARE_TAG,$CREATION_TIME,$SEED,$TARGET_DURATION,$BR" >> "$MANIFEST_PATH"
  echo "✅ done: $OUT"
done

echo "All done. Outputs in: $OUTPUT_DIR | Manifest: $MANIFEST_PATH"
