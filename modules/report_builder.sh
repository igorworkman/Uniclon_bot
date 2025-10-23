#!/bin/bash
# Report builder utilities (report.json, uniclon_report.csv)

report_builder_reset() {
  REPORT_OUTPUT_DIR="${1:-$OUTPUT_DIR}"
  ensure_dir "$REPORT_OUTPUT_DIR"
  REPORT_RESULTS=()
  REPORT_SUM_SSIM=0
  REPORT_SUM_PHASH=0
  REPORT_SUM_UNIQ=0
  REPORT_ACCEPTED=0
  REPORT_REJECTED=0
  REPORT_CSV_ROWS=()
}

report_builder__normalize_metric() {
  local value="$1" default="$2" fmt="$3"
  case "$value" in
    ""|"None"|"NA"|"N/A")
      printf '%s' "$default"
      return 0
      ;;
  esac
  if awk -v v="$value" 'BEGIN{v+=0; exit (v==v?0:1)}'; then
    if [ -n "$fmt" ]; then
      printf "$fmt" "$value"
    else
      printf '%s' "$value"
    fi
  else
    printf '%s' "$default"
  fi
}

report_builder_register_copy() {
  local copy_name="$1"
  local ssim_raw="$2"
  local psnr_raw="$3"
  local phash_raw="$4"
  local bitrate_raw="$5"
  local uniq_hint="$6"
  local validated="$7"
  local quality_pass="$8"
  local regen_flag="$9"
  local target_bitrate="${10:-}"

  local ssim_num phash_num bitrate_num uniq_num uniq_json uniq_value
  ssim_num=$(report_builder__normalize_metric "$ssim_raw" "0" "%.6f")
  phash_num=$(report_builder__normalize_metric "$phash_raw" "0" "%.2f")
  bitrate_num=$(report_builder__normalize_metric "$bitrate_raw" "0" "%.0f")

  uniq_num="0"
  uniq_json="null"
  uniq_value="$uniq_hint"
  case "$uniq_value" in
    ""|"None"|"NA"|"N/A")
      if [ "$(report_builder__normalize_metric "$phash_raw" "0" "%.1f")" != "0.0" ]; then
        if [ -z "$ssim_raw" ] || [ "$ssim_raw" = "None" ] || [ "$ssim_raw" = "NA" ] || [ "$ssim_raw" = "N/A" ]; then
          uniq_value=$(awk -v p="$phash_raw" 'BEGIN{p+=0;score=50+(p*2);if(score>100)score=100;if(score<0)score=0;printf "%.1f",score}')
        else
          uniq_value=$(awk -v s="$ssim_raw" -v p="$phash_raw" 'BEGIN{s+=0;p+=0;score=100-(s*50)+(p*1.5);if(score>100)score=100;if(score<0)score=0;printf "%.1f",score}')
        fi
      else
        uniq_value="0"
      fi
      ;;
  esac
  if [ -n "$uniq_value" ] && [ "$uniq_value" != "None" ] && [ "$uniq_value" != "NA" ] && [ "$uniq_value" != "N/A" ]; then
    uniq_num=$(awk -v u="$uniq_value" 'BEGIN{u+=0;printf "%.1f",u}')
    uniq_json="$uniq_num"
  fi

  REPORT_SUM_SSIM=$(awk -v sum="$REPORT_SUM_SSIM" -v val="$ssim_num" 'BEGIN{printf "%.6f", sum+val}')
  REPORT_SUM_PHASH=$(awk -v sum="$REPORT_SUM_PHASH" -v val="$phash_num" 'BEGIN{printf "%.6f", sum+val}')
  REPORT_SUM_UNIQ=$(awk -v sum="$REPORT_SUM_UNIQ" -v val="$uniq_num" 'BEGIN{printf "%.6f", sum+val}')

  local accepted_flag="accepted"
  if awk -v p="$phash_num" 'BEGIN{exit (p<6?0:1)}'; then
    REPORT_REJECTED=$((REPORT_REJECTED + 1))
    accepted_flag="rejected"
  elif awk -v s="$ssim_num" 'BEGIN{exit (s>0.995?0:1)}'; then
    REPORT_REJECTED=$((REPORT_REJECTED + 1))
    accepted_flag="rejected"
  else
    REPORT_ACCEPTED=$((REPORT_ACCEPTED + 1))
  fi

  local escaped_name
  escaped_name=$(printf '%s' "$copy_name" | sed 's/"/\\"/g')
  REPORT_RESULTS+=("{\"copy\":\"$escaped_name\",\"ssim\":$ssim_num,\"phash\":$phash_num,\"bitrate\":$bitrate_num,\"uniqscore\":$uniq_json}")

  REPORT_CSV_ROWS+=("$copy_name,$ssim_num,$psnr_raw,$phash_num,$bitrate_num,$target_bitrate,$uniq_json,$validated,$quality_pass,$regen_flag,$accepted_flag")
}

report_builder_finalize() {
  local total=${#REPORT_RESULTS[@]}
  [ "$total" -gt 0 ] || return 0

  local avg_ssim avg_phash avg_uniq
  avg_ssim=$(awk -v sum="$REPORT_SUM_SSIM" -v cnt="$total" 'BEGIN{cnt+=0;if(cnt<=0)cnt=1;printf "%.3f",sum/cnt}')
  avg_phash=$(awk -v sum="$REPORT_SUM_PHASH" -v cnt="$total" 'BEGIN{cnt+=0;if(cnt<=0)cnt=1;printf "%.1f",sum/cnt}')
  avg_uniq=$(awk -v sum="$REPORT_SUM_UNIQ" -v cnt="$total" 'BEGIN{cnt+=0;if(cnt<=0)cnt=1;printf "%.1f",sum/cnt}')

  local report_path="${REPORT_OUTPUT_DIR}/report.json"
  local csv_path="${REPORT_OUTPUT_DIR}/uniclon_report.csv"
  local copies_json
  copies_json=$(IFS=,; echo "${REPORT_RESULTS[*]}")
  {
    echo "{"
    echo "  \"average\": {\"SSIM\": $avg_ssim, \"pHash\": $avg_phash, \"UniqScore\": $avg_uniq},"
    echo "  \"accepted\": $REPORT_ACCEPTED,"
    echo "  \"rejected\": $REPORT_REJECTED,"
    echo "  \"copies\": [$copies_json]"
    echo "}"
  } > "$report_path"

  {
    echo "copy,ssim,psnr,phash,bitrate,target_bitrate,uniqscore,validated,quality_pass,regen,verdict"
    local row
    for row in "${REPORT_CSV_ROWS[@]}"; do
      echo "$row"
    done
  } > "$csv_path"

  echo "[Report] Saved to $report_path"
  echo "[Report] CSV saved to $csv_path"
  echo "[Summary] Avg SSIM=${avg_ssim} | Avg pHash=${avg_phash} | Avg UniqScore=${avg_uniq} | accepted=${REPORT_ACCEPTED} | rejected=${REPORT_REJECTED}"
}

build_report() {
  report_builder_finalize "$@"
}

report_builder_template_statistics() {
  local manifest_path="$1"
  [ -f "$manifest_path" ] || return
  local stats
  stats=$(awk -F',' 'NR>1 && NF>=4 {key=$3"|"$2"|"$4; count[key]++} END{for(k in count) if(count[k]>1) printf "%s %d\n",k,count[k];}' "$manifest_path")
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
