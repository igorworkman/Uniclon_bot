#!/bin/bash
# process_protective_v1.6.sh (macOS совместимая версия)
# Делает N уникальных копий из одного видео, сохраняет в "Новая папка/"
set -euo pipefail
IFS=$'\n\t'

OUTPUT_DIR="Новая папка"
MANIFEST="manifest.csv"
TARGET_W=1080
TARGET_H=1920
AUDIO_BR="128k"
BR_MIN=3200
BR_MAX=4600
FPS_CHOICES=(24 25 30 50 59.615 60)
NOISE_PROB_PERCENT=30
CROP_MAX_PX=6
AUDIO_TWEAK_PROB_PERCENT=50

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

if [ ! -f "$MANIFEST" ]; then
  echo "timestamp,input,output,uid,fps,video_kbps,width,height,noise_level,crop_px,audio_tweak,encoder" > "$MANIFEST"
fi

# helpers
rand_int() { local A="$1" B="$2"; echo $(( A + RANDOM % (B - A + 1) )); }
# bash 3 совместимый выбор случайного элемента массива
rand_choice() {
  local arrname=$1[@]
  local arr=("${!arrname}")
  echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}
rand_audio_factor() { awk -v r="$RANDOM" 'BEGIN{srand(r); printf "%.6f", 0.995 + rand()*0.01}'; }

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

rand_description() {
  local choices=(
    "Edited on mobile"
    "Final export"
    "Captured on phone"
    "Shot in portrait"
    "Quick highlight"
  )
  local idx=$((RANDOM % ${#choices[@]}))
  echo "${choices[$idx]}"
}

base="$(basename "$SRC")"
name="${base%.*}"

for ((i=1;i<=COUNT;i++)); do
  # UID
  if command -v uuidgen >/dev/null 2>&1; then
    UID_HEX=$(uuidgen | sed 's/-//g' | cut -c1-8)
  else
    UID_HEX=$(printf "%08X" $RANDOM)
  fi
  UID_TAG="UID-${UID_HEX}_$(date +%s)"

  FPS=$(rand_choice FPS_CHOICES)
  BR=$(rand_int "$BR_MIN" "$BR_MAX")
  MAXRATE=$(( BR + 500 ))
  BUFSIZE=$(( BR * 2 ))

  NOISE=0; if [ "$(rand_int 1 100)" -le "$NOISE_PROB_PERCENT" ]; then NOISE=1; fi
  CROP_PX=$(rand_int 0 "$CROP_MAX_PX")

  AUDIO_TWEAK=0
  AFILTER="aresample=44100"
  if [ "$(rand_int 1 100)" -le "$AUDIO_TWEAK_PROB_PERCENT" ]; then
    AUDIO_TWEAK=1
    FACTOR="$(rand_audio_factor)"
    AFILTER="asetrate=44100*${FACTOR},aresample=44100"
  fi

  ENC_MINOR=$(rand_int 2 5)
  ENC_PATCH=$(rand_int 0 255)
  ENCODER_TAG=$(printf "Lavf62.%d.%03d" "$ENC_MINOR" "$ENC_PATCH")

  if [ $((RANDOM % 2)) -eq 0 ]; then
    SOFTWARE_TAG="CapCut 12.$(rand_int 1 9)"
  else
    SOFTWARE_TAG="VN 2.$(rand_int 1 9)"
  fi

  CREATION_TIME=$(generate_iso_timestamp)
  CREATION_TIME_EXIF=$(echo "$CREATION_TIME" | sed 's/T/ /; s/Z$//; s/-/:/g')

  compact_ts="${CREATION_TIME//[-:TZ]/}"
  TITLE="VID_${compact_ts:0:8}_${compact_ts:8:6}"
  DESCRIPTION="$(rand_description)"

  VF="scale=${TARGET_W}:${TARGET_H}:flags=lanczos,setsar=1"
  VF="${VF},eq=brightness=0.005:saturation=1.01"
  if [ "$NOISE" -eq 1 ]; then VF="${VF},noise=alls=1:allf=t"; fi
  if [ "$CROP_PX" -gt 0 ]; then
    dbl=$((CROP_PX*2))
    VF="${VF},crop=in_w-${dbl}:in_h-${dbl}:${CROP_PX}:${CROP_PX},pad=iw+${dbl}:ih+${dbl}:${CROP_PX}:${CROP_PX}"
  fi
  VF="${VF},drawtext=text='${UID_TAG}':fontcolor=white@0.08:fontsize=16:x=10:y=H-30"

  OUT="${OUTPUT_DIR}/${name}_final_v${i}.mp4"
  echo "▶️ [$i/$COUNT] $SRC → $OUT | fps=$FPS br=${BR}k noise=$NOISE crop=${CROP_PX}px audio_tweak=$AUDIO_TWEAK"

  ffmpeg -y -hide_banner -loglevel warning -i "$SRC" \
    -c:v libx264 -preset slow -profile:v high -level 4.0 \
    -r "$FPS" -b:v "${BR}k" -maxrate "${MAXRATE}k" -bufsize "${BUFSIZE}k" \
    -vf "$VF" \
    -c:a aac -b:a "$AUDIO_BR" -af "$AFILTER" \
    -movflags +faststart \
    -metadata encoder="$ENCODER_TAG" \
    -metadata software="$SOFTWARE_TAG" \
    -metadata creation_time="$CREATION_TIME" \
    -metadata title="$TITLE" \
    -metadata description="$DESCRIPTION" \
    -metadata comment="$UID_TAG" \
    "$OUT"

  exiftool -overwrite_original \
    -GPS:all= -Location:all= -SerialNumber= \
    -Software="$SOFTWARE_TAG" \
    -CreateDate="$CREATION_TIME_EXIF" -ModifyDate="$CREATION_TIME_EXIF" \
    -QuickTime:CreateDate="$CREATION_TIME_EXIF" -QuickTime:ModifyDate="$CREATION_TIME_EXIF" \
    "$OUT" >/dev/null

  WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$OUT")
  HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$OUT")
  VKBPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$OUT")
  VKBPS=$((VKBPS/1000))
  ENC=$(ffprobe -v error -show_entries format_tags=encoder -of csv=p=0 "$OUT")

  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$SRC,$OUT,$UID_TAG,$FPS,$VKBPS,$WIDTH,$HEIGHT,$NOISE,$CROP_PX,$AUDIO_TWEAK,$ENC" >> "$MANIFEST"
  echo "✅ done: $OUT"
done

echo "All done. Outputs in: $OUTPUT_DIR | Manifest: $MANIFEST"
