#!/bin/bash
# Metrics helpers for SSIM/PSNR/pHash processing

metrics_compute_phash_diff() {
  local source_file="$1" compare_file="$2" value="NA"
  local py_path="${BASE_DIR}"
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

metrics_calculate_uniqscore() {
  local ssim_val="$1" psnr_val="$2" phash_val="$3"
  local phash_numeric
  phash_numeric=$(awk -v v="$phash_val" 'BEGIN{if(v==""||v=="None"||v=="NA"||v=="N/A"){print "0"}else{printf "%.3f",v+0}}')
  awk -v s="$ssim_val" -v p="$psnr_val" -v h="$phash_numeric" 'BEGIN {
    s+=0; p+=0; h+=0;
    score = (100*h/50) * (1 - (s-0.9)/0.1) * (p/40);
    if (score > 100) score=100;
    if (score < 0) score=0;
    printf "%.1f", score;
  }'
}

metrics_compute_copy_metrics() {
  local source_file="$1" compare_file="$2"
  local ssim_val psnr_val phash_val metrics_log compare_name
  compare_name="${compare_file##*/}"
  metrics_log="${CHECK_DIR}/metrics_${compare_name%.*}.log"
  {
    ffmpeg_exec -hide_banner -i "$source_file" -i "$compare_file" \
      -lavfi "[0:v][1:v]ssim;[0:v][1:v]psnr" -f null - 2>&1 || true
  } | tee "$metrics_log" >/dev/null
  ssim_val=$({ grep -o 'SSIM=[0-9\.]*' "$metrics_log" || true; } | tail -1 | cut -d= -f2)
  psnr_val=$({ grep -o 'PSNR_mean:[0-9\.]*' "$metrics_log" || true; } | tail -1 | cut -d: -f2)
  ssim_val=${ssim_val:-0.995}
  psnr_val=${psnr_val:-35.0}
  local bitrate_val="None"
  local bitrate_probe=""
  bitrate_probe=$(ffprobe_exec -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$compare_file" 2>/dev/null || true)
  if [ -n "$bitrate_probe" ] && awk -v val="$bitrate_probe" 'BEGIN{val+=0; exit (val>0 ? 0 : 1)}'; then
    bitrate_val=$(awk -v val="$bitrate_probe" 'BEGIN{printf "%.0f", val/1000}')
  fi
  local delta_bitrate="None"
  if [ "$bitrate_val" != "None" ] && [ "${SRC_BITRATE:-None}" != "None" ]; then
    delta_bitrate=$(awk -v src="${SRC_BITRATE:-0}" -v copy="$bitrate_val" 'BEGIN{ if(src>0 && copy>0) printf "%.1f", (100*(copy-src)/src); else print "None" }')
    [ -n "$delta_bitrate" ] || delta_bitrate="None"
  fi
  phash_val=$(metrics_compute_phash_diff "$source_file" "$compare_file")
  case "$phash_val" in
    ""|"None"|"NA"|"N/A") phash_val="0" ;;
  esac
  local phash_numeric
  phash_numeric=$(awk -v v="$phash_val" 'BEGIN{ if (v ~ /^[0-9.]+$/) { printf "%.1f", v+0 } else { printf "0.0" } }')
  phash_val=$(awk -v v="$phash_val" 'BEGIN{ if (v ~ /^[0-9.]+$/) { printf "%.0f", v } else { print "0" } }')
  local uniq_score
  uniq_score=$(metrics_calculate_uniqscore "$ssim_val" "$psnr_val" "$phash_numeric")
  echo "[Metrics] SSIM=${ssim_val}  PSNR=${psnr_val}  pHash=${phash_val}  → UniqScore=${uniq_score}"
  if [ -n "${LOG:-}" ]; then
    echo "[Metrics] SSIM=${ssim_val}  PSNR=${psnr_val}  pHash=${phash_val}  → UniqScore=${uniq_score}" >>"$LOG"
  fi
  local delta_log="None"
  local delta_suffix=""
  if [ "$delta_bitrate" != "None" ]; then
    delta_log=$(awk -v d="$delta_bitrate" 'BEGIN{d+=0; printf "%+.1f", d}')
    delta_suffix="%"
  fi
  local bitrate_suffix=""
  local bitrate_log="None"
  if [ "$bitrate_val" != "None" ]; then
    bitrate_log="$bitrate_val"
    bitrate_suffix=" kb/s"
  fi
  echo "[Metrics] Bitrate=${bitrate_log}${bitrate_suffix} | Δ=${delta_log}${delta_suffix} | UniqScore=${uniq_score}"
  if [ -n "${LOG:-}" ]; then
    echo "[Metrics] Bitrate=${bitrate_log}${bitrate_suffix} | Δ=${delta_log}${delta_suffix} | UniqScore=${uniq_score}" >>"$LOG"
  fi
  local metrics_manifest="${CHECK_DIR}/copy_metrics.json"
  python3 - "$metrics_manifest" "$compare_name" "$ssim_val" "$psnr_val" "$phash_val" "$bitrate_val" "$delta_bitrate" "$uniq_score" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
copy_name, ssim_raw, psnr_raw, phash_raw, bitrate_raw, delta_raw, uniq_raw = sys.argv[2:9]


def _parse_float(value: str):
    if value in ("", "None", "NA", "N/A"):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _parse_int(value: str):
    if value in ("", "None", "NA", "N/A"):
        return None
    try:
        return int(float(value))
    except ValueError:
        return None

entry = {
    "copy": copy_name,
    "ssim": _parse_float(ssim_raw),
    "psnr": _parse_float(psnr_raw),
    "phash": _parse_int(phash_raw),
    "bitrate": _parse_int(bitrate_raw),
    "delta_bitrate": _parse_float(delta_raw),
    "UniqScore": _parse_float(uniq_raw),
}

try:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        data = []
except FileNotFoundError:
    data = []
except Exception:
    data = []

data = [item for item in data if item.get("copy") != copy_name]
data.append(entry)
manifest_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
PY
  printf '%s|%s|%s|%s|%s|%s' "$ssim_val" "$psnr_val" "$phash_val" "$bitrate_val" "$delta_bitrate" "$uniq_score"
}
