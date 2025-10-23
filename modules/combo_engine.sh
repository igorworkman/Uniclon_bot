#!/bin/bash

RUN_COMBO_POS=0

# REGION Orchestrator state helpers (shared via sourcing)
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

variant_key_seen() {
  local key="$1" existing
  if [ -z "${USED_VARIANT_KEYS_LIST:-}" ]; then
    return 1
  fi
  while IFS= read -r existing; do
    [ -z "$existing" ] && continue
    if [ "$existing" = "$key" ]; then
      return 0
    fi
  done <<EOF
${USED_VARIANT_KEYS_LIST}
EOF
  return 1
}

mark_variant_key() {
  local key="$1"
  : "${USED_VARIANT_KEYS_LIST:=}"
  if variant_key_seen "$key"; then
    return
  fi
  if [ -z "$USED_VARIANT_KEYS_LIST" ]; then
    USED_VARIANT_KEYS_LIST="$key"
  else
    USED_VARIANT_KEYS_LIST="${USED_VARIANT_KEYS_LIST}"$'\n'"$key"
  fi
}

unmark_variant_key() {
  local key="$1" existing new_list=""
  if [ -z "${USED_VARIANT_KEYS_LIST:-}" ]; then
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
${USED_VARIANT_KEYS_LIST}
EOF
  USED_VARIANT_KEYS_LIST="$new_list"
}
# END REGION

# REGION AI: safe filter quoting
_combo_escape_single_quotes() {
  local value="$1"
  value=${value//\'/\'"\'"\'}
  printf '%s' "$value"
}

safe_vf() {
  local vf="$1"
  if [[ -z "$vf" ]]; then
    printf "''"
    return
  fi
  if [[ ${vf:0:1} == "'" && ${vf: -1} == "'" ]]; then
    printf '%s' "$vf"
    return
  fi
  local escaped
  escaped=$(_combo_escape_single_quotes "$vf")
  escaped=${escaped//(/\\(}
  escaped=${escaped//)/\\)}
  printf "'%s'" "$escaped"
}

_combo_protect_vf_parens() {
  local combo="$1"
  [[ "$combo" == *"CUR_VF_EXTRA"* ]] || { printf '%s' "$combo"; return; }
  combo+=$'\n# Escape parentheses to prevent syntax errors in bash -c\n'
  combo+=$'CUR_VF_EXTRA_SAFE="${CUR_VF_EXTRA//(/\\(}"\n'
  combo+=$'CUR_VF_EXTRA_SAFE="${CUR_VF_EXTRA_SAFE//)/\\)}"\n'
  combo+=$'CUR_VF_EXTRA="$CUR_VF_EXTRA_SAFE"'
  printf '%s' "$combo"
}
# END REGION AI

_combo_format_filter_arg() {
  local arg="$1"
  if [[ -z "$arg" ]]; then
    printf '%q' ""
    return
  fi
  if [[ ${arg:0:1} == "'" && ${arg: -1} == "'" ]]; then
    printf '%s' "$arg"
    return
  fi
  if [[ "$arg" == *"("* || "$arg" == *")"* \
      || "$arg" == *"scale="* || "$arg" == *"crop="* \
      || "$arg" == *"rotate="* || "$arg" == *"hue="* \
      || "$arg" == *"vignette="* || "$arg" == *"lut"* \
      || "$arg" == *"mirror"* ]]; then
    printf '%s' "$(safe_vf "$arg")"
    return
  fi
  printf '%q' "$arg"
}

ffmpeg_command_preview() {
  local -a args=("$@")
  local preview
  preview=$(printf '%q' ffmpeg)
  local expect_filter=0
  local idx arg formatted
  for ((idx = 0; idx < ${#args[@]}; idx++)); do
    arg="${args[$idx]}"
    if (( expect_filter )); then
      formatted=$(_combo_format_filter_arg "$arg")
      expect_filter=0
    else
      formatted=$(printf '%q' "$arg")
      case "$arg" in
        -vf|-af|-filter_complex|-lavfi|-filter_complex_script)
          expect_filter=1
          ;;
      esac
    fi
    preview+=" ${formatted}"
  done
  printf '%s' "$preview"
}

ensure_run_combos() {
  local total=${#RUN_COMBOS[@]:-0}
  [ "$RUN_COMBO_POS" -ge "$total" ] && total=0
  [ "$total" -ge 8 ] && return
  RUN_COMBOS=(
    "CFPS=30 CNOISE=1 CMIRROR=hflip CAUDIO=asetrate CBR=1.12 CSHIFT=0.07 CSOFT=VN CLEVEL=4.0"
    "CFPS=60 CNOISE=0 CMIRROR=none CAUDIO=resample CBR=0.88 CSHIFT=-0.05 CSOFT=CapCut CLEVEL=4.2"
    "CFPS=30 CNOISE=0 CMIRROR=vflip CAUDIO=jitter CBR=1.10 CSHIFT=0.09 CSOFT=LumaFusion CLEVEL=4.0"
    "CFPS=24 CNOISE=1 CMIRROR=none CAUDIO=asetrate CBR=0.90 CSHIFT=-0.08 CSOFT=CapCut CLEVEL=4.0"
    "CFPS=25 CNOISE=0 CMIRROR=hflip CAUDIO=resample CBR=1.15 CSHIFT=0.06 CSOFT=VN CLEVEL=4.2"
    "CFPS=30 CNOISE=1 CMIRROR=none CAUDIO=jitter CBR=0.85 CSHIFT=-0.10 CSOFT=LumaFusion CLEVEL=4.0"
    "CFPS=60 CNOISE=1 CMIRROR=none CAUDIO=asetrate CBR=1.13 CSHIFT=0.12 CSOFT=CapCut CLEVEL=4.2"
    "CFPS=30 CNOISE=0 CMIRROR=none CAUDIO=resample CBR=0.87 CSHIFT=-0.07 CSOFT=VN CLEVEL=4.0"
  )
  RUN_COMBO_POS=0
}

next_regen_combo() {
  ensure_run_combos
  if [ "$RUN_COMBO_POS" -lt "${#RUN_COMBOS[@]}" ]; then
    printf '%s' "${RUN_COMBOS[$RUN_COMBO_POS]}"
    RUN_COMBO_POS=$((RUN_COMBO_POS + 1))
  else
    printf ''
  fi
}

generate_dynamic_combo() {
  local ident=$(rand_int 120 999)
  local vf_options=(
    "tblend=average"
    "edgedetect=mode=colormix:high=0.10:low=0.04"
    "smartblur=ls=2.5"
    "eq=brightness=0.02:saturation=1.08"
    "hue=h=20*PI/180"
  )
  local af_options=(
    "vibrato=f=8:d=0.6"
    "aphaser=0.7:0.9:0.3:0.7:0.5:0.5"
    "compand=attacks=0:decays=0.8:points=-45/-45|-15/-3|0/-0.5"
    "flanger=delay=8:depth=2:regen=0.4:speed=0.3"
    "chorus=0.7:0.8:40:0.5:0.3:2"
  )
  local mirrors=(none hflip vflip)
  local audios=(asetrate resample jitter)
  local softwares=(CapCut VN LumaFusion)
  local fps_pool=(24 25 30 60)
  local br_pool=(0.85 0.92 1.05 1.12)
  local shift_pool=(-0.08 -0.04 0.05 0.09)
  local level_pool=(4.0 4.2)
  local vf_idx=$(rand_int 0 $(( ${#vf_options[@]} - 1 )))
  local af_idx=$(rand_int 0 $(( ${#af_options[@]} - 1 )))
  local mirror_idx=$(rand_int 0 $(( ${#mirrors[@]} - 1 )))
  local audio_idx=$(rand_int 0 $(( ${#audios[@]} - 1 )))
  local soft_idx=$(rand_int 0 $(( ${#softwares[@]} - 1 )))
  local fps_idx=$(rand_int 0 $(( ${#fps_pool[@]} - 1 )))
  local br_idx=$(rand_int 0 $(( ${#br_pool[@]} - 1 )))
  local shift_idx=$(rand_int 0 $(( ${#shift_pool[@]} - 1 )))
  local level_idx=$(rand_int 0 $(( ${#level_pool[@]} - 1 )))
  local noise=$(rand_int 0 1)
  local combo
  combo=$(printf "CUR_COMBO_LABEL='auto_%s' CFPS=%s CNOISE=%s CMIRROR=%s CAUDIO=%s CBR=%s CSHIFT=%s CSOFT=%s CLEVEL=%s CUR_VF_EXTRA=\\\"%s\\\" CUR_AF_EXTRA=\\\"%s\\\"" \
    "$ident" "${fps_pool[$fps_idx]}" "$noise" "${mirrors[$mirror_idx]}" "${audios[$audio_idx]}" \
    "${br_pool[$br_idx]}" "${shift_pool[$shift_idx]}" "${softwares[$soft_idx]}" "${level_pool[$level_idx]}" \
    "${vf_options[$vf_idx]}" "${af_options[$af_idx]}")
  combo=$(_combo_protect_vf_parens "$combo")
  combo="${combo//(/\(}"
  combo="${combo//)/\)}"
  printf '%s' "$combo"
}

auto_expand_run_combos() {
  local total=${#RUN_PHASH[@]}
  [ "$total" -lt 3 ] && return
  [ "${#RUN_COMBOS[@]}" -ge 16 ] && return
  local sum=0 count=0 idx
  for idx in "${RUN_PHASH[@]}"; do
    [ -z "$idx" ] || [ "$idx" = "NA" ] || [ "$idx" = "N/A" ] || [ "$idx" = "None" ] && continue
    sum=$(awk -v acc="$sum" -v val="$idx" 'BEGIN{acc+=0;val+=0;printf "%.6f",acc+val}')
    count=$((count + 1))
  done
  [ "$count" -lt 3 ] && return
  local avg=$(awk -v acc="$sum" -v c="$count" 'BEGIN{if(c<=0){print 0}else{printf "%.3f",acc/c}}')
  awk -v a="$avg" 'BEGIN{exit (a<5?0:1)}' || return
  local new_combo=$(generate_dynamic_combo)
  [ -z "$new_combo" ] && return
  RUN_COMBOS+=("$new_combo")
  local CUR_COMBO_LABEL="" CUR_VF_EXTRA="" CUR_AF_EXTRA="" CFPS="" CNOISE="" CMIRROR="" CAUDIO="" CSHIFT="" CBR="" CSOFT="" CLEVEL=""
  eval "$new_combo"
  local label="${CUR_COMBO_LABEL:-auto}"
  echo "[Strategy] Auto-added combo → ${label}"
}

generate_run_combos() {
  local -a predefined=(
    "CUR_COMBO_LABEL='fps24_eq_boost' CFPS=30 CNOISE=1 CMIRROR=hflip CAUDIO=asetrate CBR=1.12 CSHIFT=0.07 CSOFT=VN CLEVEL=4.0 CUR_VF_EXTRA=\\\"fps=24,eq=brightness=0.03:contrast=1.02\\\" CUR_AF_EXTRA=\\\"acompressor=threshold=-16dB:ratio=2.4,aresample=44100\\\""
    "CUR_COMBO_LABEL='vflip_curves' CFPS=60 CNOISE=0 CMIRROR=vflip CAUDIO=resample CBR=0.88 CSHIFT=-0.05 CSOFT=CapCut CLEVEL=4.2 CUR_VF_EXTRA=\\\"vflip,curves=preset=strong_contrast\\\" CUR_AF_EXTRA=\\\"apulsator=mode=sine:freq=0.8,atempo=0.99\\\""
    "CUR_COMBO_LABEL='crop_rotate' CFPS=30 CNOISE=0 CMIRROR=none CAUDIO=jitter CBR=1.10 CSHIFT=0.09 CSOFT=LumaFusion CLEVEL=4.0 CUR_VF_EXTRA=\\\"crop=in_w-20:in_h-20,rotate=0.5*(PI/180):fillcolor=black\\\" CUR_AF_EXTRA=\\\"atempo=1.02,treble=g=1.5\\\""
    "CUR_COMBO_LABEL='hflip_noise' CFPS=24 CNOISE=1 CMIRROR=hflip CAUDIO=asetrate CBR=0.90 CSHIFT=-0.08 CSOFT=CapCut CLEVEL=4.0 CUR_VF_EXTRA=\\\"hflip,noise=alls=5:allf=t+u\\\" CUR_AF_EXTRA=\\\"acompressor=threshold=-20dB:ratio=3.0,lowpass=f=12000\\\""
    "CUR_COMBO_LABEL='colorbalance_pop' CFPS=25 CNOISE=0 CMIRROR=hflip CAUDIO=resample CBR=1.15 CSHIFT=0.06 CSOFT=VN CLEVEL=4.2 CUR_VF_EXTRA=\\\"colorbalance=bs=0.05:rs=-0.05,eq=saturation=1.1\\\" CUR_AF_EXTRA=\\\"equalizer=f=1200:t=q:w=1.0:g=-3\\\""
    "CUR_COMBO_LABEL='vignette_gamma' CFPS=30 CNOISE=1 CMIRROR=none CAUDIO=jitter CBR=0.85 CSHIFT=-0.10 CSOFT=LumaFusion CLEVEL=4.0 CUR_VF_EXTRA=\\\"vignette=PI/5:0.5,eq=gamma=1.03\\\" CUR_AF_EXTRA=\\\"crystalizer=i=2\\\""
    "CUR_COMBO_LABEL='rotate_pad' CFPS=60 CNOISE=1 CMIRROR=none CAUDIO=asetrate CBR=1.13 CSHIFT=0.12 CSOFT=CapCut CLEVEL=4.2 CUR_VF_EXTRA=\\\"rotate=-0.3*(PI/180):fillcolor=black\\\" CUR_AF_EXTRA=\\\"highpass=f=200,atempo=0.98\\\""
    "CUR_COMBO_LABEL='unsharp_speed' CFPS=30 CNOISE=0 CMIRROR=none CAUDIO=resample CBR=0.87 CSHIFT=-0.07 CSOFT=VN CLEVEL=4.0 CUR_VF_EXTRA=\\\"unsharp=3:3:1.5,setpts=PTS*0.98\\\" CUR_AF_EXTRA=\\\"chorus=0.6:0.9:55:0.4:0.25:2\\\""
    "CUR_COMBO_LABEL='curves_light' CFPS=30 CNOISE=1 CMIRROR=vflip CAUDIO=jitter CBR=1.05 CSHIFT=0.04 CSOFT=VN CLEVEL=4.0 CUR_VF_EXTRA=\\\"curves=preset=lighter\\\" CUR_AF_EXTRA=\\\"superequalizer=1b=0.8:2b=0.4:3b=0.1:4b=-0.2:5b=-0.4\\\""
    "CUR_COMBO_LABEL='hue_noise' CFPS=24 CNOISE=0 CMIRROR=none CAUDIO=asetrate CBR=0.95 CSHIFT=-0.03 CSOFT=CapCut CLEVEL=4.0 CUR_VF_EXTRA=\\\"hue=s=0.95,noise=alls=3:allf=t\\\" CUR_AF_EXTRA=\\\"aecho=0.7:0.4:30:0.6\\\""
  )
  RUN_COMBOS=()
  local combo vf vf_escaped
  for combo in "${predefined[@]}"; do
    if [[ $combo =~ CUR_VF_EXTRA=\"([^\"]*)\" ]]; then
      vf="${BASH_REMATCH[1]}"
      vf_escaped=$(safe_vf "$vf")
      combo="${combo/CUR_VF_EXTRA=\"${vf}\"/CUR_VF_EXTRA=\"${vf_escaped}\"}"
    fi
    combo=$(_combo_protect_vf_parens "$combo")
    combo="${combo//(/\(}"
    combo="${combo//)/\)}"
    RUN_COMBOS+=("$combo")
  done
  RUN_COMBO_POS=0
}

combo_engine_autofill() {
  if [[ -z "${RUN_COMBOS[*]-}" ]]; then
    echo "[Init] RUN_COMBOS not set — generating default pool..."
    generate_run_combos
  fi
}
