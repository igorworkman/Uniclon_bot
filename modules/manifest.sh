#!/bin/bash
# Manifest helpers (manifest.csv handling)

MANIFEST_HEADER="filename,bitrate,fps,duration,size_kb,encoder,software,creation_time,seed,target_duration,target_bitrate,validated,regen,profile,qt_make,qt_model,qt_software,ssim,psnr,phash,quality_pass,quality,fallback_reason,combo_used,attempts,creative_mirror,creative_intro,creative_lut,preview"

manifest__escape_csv_field() {
  local value="$1"
  value="${value//\"/\"\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

manifest__legacy_upgrade() {
  local manifest_path="$1"
  if ! head -n1 "$manifest_path" | grep -q "target_duration"; then
    local tmp=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},target_duration,target_bitrate,validated,regen"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлены колонки target_duration, target_bitrate, validated, regen"
  elif ! head -n1 "$manifest_path" | grep -q ",validated"; then
    local tmp=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},validated,regen"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},," 
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлены колонки validated и regen"
  fi
  if ! head -n1 "$manifest_path" | grep -q ",profile"; then
    local tmp=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},profile"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлена колонка profile"
  fi
  if ! head -n1 "$manifest_path" | grep -q ",qt_make"; then
    local tmp=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},qt_make,qt_model,qt_software"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлены колонки qt_make, qt_model и qt_software"
  fi
  local header_line
  header_line=$(head -n1 "$manifest_path")
  if printf '%s' "$header_line" | grep -q "phash_delta"; then
    local tmp=$(mktemp)
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
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: колонки ssim, psnr и phash приведены к новому формату"
  fi
  header_line=$(head -n1 "$manifest_path")
  if ! printf '%s' "$header_line" | grep -q ",psnr,"; then
    local tmp=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},ssim,psnr,phash,quality_pass"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлены колонки ssim, psnr, phash и quality_pass"
  elif ! printf '%s' "$header_line" | grep -q ",phash,"; then
    local tmp=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},phash"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлена колонка phash"
  fi
  header_line=$(head -n1 "$manifest_path")
  if ! printf '%s' "$header_line" | grep -q ",quality$"; then
    local tmp=$(mktemp)
    {
      IFS= read -r current_header
      echo "${current_header},quality"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлена колонка quality"
  fi
  if ! head -n1 "$manifest_path" | grep -q ",creative_mirror"; then
    local tmp=$(mktemp)
    {
      IFS= read -r header_line
      echo "${header_line},creative_mirror,creative_intro,creative_lut,preview"
      while IFS= read -r data_line; do
        [ -z "$data_line" ] && continue
        echo "${data_line},,,,"
      done
    } < "$manifest_path" > "$tmp"
    mv "$tmp" "$manifest_path"
    echo "ℹ️ manifest обновлён: добавлены creative-колонки и preview"
  fi
}

manifest__rewrite_with_header() {
  local manifest_path="$1"
  local tmp=$(mktemp)
  {
    IFS= read -r _old_header || true
    echo "$MANIFEST_HEADER"
    while IFS= read -r data_line; do
      [ -z "$data_line" ] && continue
      local current_fields required_fields
      current_fields=$(awk -F',' '{print NF}' <<<"$data_line")
      required_fields=$(awk -F',' '{print NF}' <<<"$MANIFEST_HEADER")
      while [ "$current_fields" -lt "$required_fields" ]; do
        data_line="${data_line},"
        current_fields=$((current_fields + 1))
      done
      echo "$data_line"
    done
  } < "$manifest_path" > "$tmp"
  mv "$tmp" "$manifest_path"
}

manifest_init() {
  local manifest_path="$1"
  ensure_dir "$(dirname "$manifest_path")"
  if [ ! -f "$manifest_path" ]; then
    echo "$MANIFEST_HEADER" > "$manifest_path"
    return 0
  fi
  manifest__legacy_upgrade "$manifest_path"
  manifest__rewrite_with_header "$manifest_path"
}

manifest_write_entry() {
  local manifest_path="$1"
  local idx="$2"
  local validated_flag="$3"
  local regen_flag="$4"
  local line
  local combo_field
  combo_field=$(manifest__escape_csv_field "${RUN_COMBO_USED[$idx]}")
  line="${RUN_FILES[$idx]},${RUN_BITRATES[$idx]},${RUN_FPS[$idx]},${RUN_DURATIONS[$idx]},${RUN_SIZES[$idx]},${RUN_ENCODERS[$idx]},${RUN_SOFTWARES[$idx]},${RUN_CREATION_TIMES[$idx]},${RUN_SEEDS[$idx]},${RUN_TARGET_DURS[$idx]},${RUN_TARGET_BRS[$idx]},$validated_flag,$regen_flag,${RUN_PROFILES[$idx]},${RUN_QT_MAKES[$idx]},${RUN_QT_MODELS[$idx]},${RUN_QT_SOFTWARES[$idx]},${RUN_SSIM[$idx]},${RUN_PSNR[$idx]},${RUN_PHASH[$idx]},${RUN_QPASS[$idx]},${RUN_QUALITIES[$idx]},${RUN_FALLBACK_REASON[$idx]},${combo_field},${RUN_ATTEMPTS[$idx]},${RUN_CREATIVE_MIRROR[$idx]},${RUN_CREATIVE_INTRO[$idx]},${RUN_CREATIVE_LUT[$idx]},${RUN_PREVIEWS[$idx]}"
  echo "$line" >> "$manifest_path"
}

write_manifest() {
  manifest_write_entry "$@"
}

# REGION AI: fallback CUR_VF_EXTRA quoting fix
escape_filter() {
  local input="$1"
  if [ -z "$input" ]; then
    printf ''
    return
  fi
  if [ "${input:0:1}" = '"' ] && [ "${input: -1}" = '"' ]; then
    input="${input:1:-1}"
  elif [ "${input:0:1}" = "'" ] && [ "${input: -1}" = "'" ]; then
    input="${input:1:-1}"
  fi
  input="${input//\(/(}"
  input="${input//\)/)}"
  input="${input//(/\(}"
  input="${input//)/\)}"
  printf '%s' "$input"
}

manifest__fallback_vf_extra() {
  local CUR_VF_EXTRA
  CUR_VF_EXTRA="fps=24,eq=brightness=0.03:contrast=1.02"
  CUR_VF_EXTRA=$(escape_filter "$CUR_VF_EXTRA")
  printf '%s' "$CUR_VF_EXTRA"
}
# END REGION AI
