#!/bin/bash

if ! declare -F safe_vf >/dev/null 2>&1; then
  _creative_utils_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${_creative_utils_root}/combo_engine.sh" ]; then
    # shellcheck source=modules/combo_engine.sh
    source "${_creative_utils_root}/combo_engine.sh"
  fi
  unset _creative_utils_root
fi

creative_unwrap_vf() {
  local payload="$1"
  if [ -z "$payload" ]; then
    printf '%s' ""
    return
  fi
  if [[ ${payload:0:1} == "'" && ${payload: -1} == "'" && ${#payload} -ge 2 ]]; then
    payload="${payload:1:${#payload}-2}"
  fi
  payload=${payload//\'"\'"\'/\'}
  printf '%s' "$payload"
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

compose_vf_chain() {
  local base="$1" extra="$2"
  local base_safe extra_safe base_raw extra_raw joined

  base_safe=$(safe_vf "$base")
  extra_safe=$(safe_vf "$extra")

  base_raw=$(creative_unwrap_vf "$base_safe")
  extra_raw=$(creative_unwrap_vf "$extra_safe")

  if [ -z "$extra_raw" ]; then
    CREATIVE_LAST_VF_SAFE="$base_safe"
    printf '%s' "$base_raw"
    return
  fi
  if [ -z "$base_raw" ]; then
    CREATIVE_LAST_VF_SAFE="$extra_safe"
    printf '%s' "$extra_raw"
    return
  fi

  joined=$(printf '%s,%s' "$base_raw" "$extra_raw")
  CREATIVE_LAST_VF_SAFE=$(safe_vf "$joined")
  printf '%s' "$joined"
}

ensure_vf_format() {
  local payload="$1"
  local payload_safe payload_raw
  payload_safe=$(safe_vf "$payload")
  payload_raw=$(creative_unwrap_vf "$payload_safe")
  if [ -z "$payload_raw" ]; then
    CREATIVE_LAST_VF_SAFE=$(safe_vf "format=yuv420p")
    printf '%s' "format=yuv420p"
    return
  fi
  case ",${payload_raw}," in
    *,format=yuv420p,*)
      CREATIVE_LAST_VF_SAFE=$(safe_vf "$payload_raw")
      printf '%s' "$payload_raw"
      ;;
    *)
      payload_raw="${payload_raw},format=yuv420p"
      CREATIVE_LAST_VF_SAFE=$(safe_vf "$payload_raw")
      printf '%s' "$payload_raw"
      ;;
  esac
}

creative_pick_mirror() {
  local enable="$1"
  local override="$2"
  MIRROR_ACTIVE=0
  MIRROR_FILTER=""
  MIRROR_FILTER_SAFE=""
  MIRROR_DESC="none"
  if [ -n "$override" ]; then
    if [ "$override" = "none" ]; then
      return
    fi
    MIRROR_ACTIVE=1
    local vf_safe
    vf_safe=$(safe_vf "$override")
    MIRROR_FILTER=$(creative_unwrap_vf "$vf_safe")
    MIRROR_FILTER_SAFE="$vf_safe"
    MIRROR_DESC="$override"
    return
  fi
  if [ "$enable" -ne 1 ]; then
    return
  fi
  MIRROR_ACTIVE=1
  if [ "$(rand_int 0 1)" -eq 0 ]; then
    local vf_safe
    vf_safe=$(safe_vf "hflip")
    MIRROR_FILTER=$(creative_unwrap_vf "$vf_safe")
    MIRROR_FILTER_SAFE="$vf_safe"
  else
    local vf_safe
    vf_safe=$(safe_vf "vflip")
    MIRROR_FILTER=$(creative_unwrap_vf "$vf_safe")
    MIRROR_FILTER_SAFE="$vf_safe"
  fi
  MIRROR_DESC="$MIRROR_FILTER"
}

creative_pick_lut() {
  local enable="$1"
  local array_name="$2"
  LUT_ACTIVE=0
  LUT_FILTER=""
  LUT_FILTER_SAFE=""
  LUT_DESC="none"
  if [ "$enable" -ne 1 ]; then
    return
  fi
  local -n lut_array="$array_name"
  LUT_ACTIVE=1
  if [ ${#lut_array[@]} -gt 0 ]; then
    local lut_choice
    lut_choice=$(rand_choice "$array_name")
    LUT_DESC="$(basename "$lut_choice")"
    LUT_DESC="${LUT_DESC//,/ _}"
    local lut_filter="lut3d=file='$(escape_single_quotes "$lut_choice")':interp=tetrahedral"
    local vf_safe
    vf_safe=$(safe_vf "$lut_filter")
    LUT_FILTER=$(creative_unwrap_vf "$vf_safe")
    LUT_FILTER_SAFE="$vf_safe"
  else
    LUT_DESC="curves_vintage"
    local lut_filter="curves=preset=vintage"
    local vf_safe
    vf_safe=$(safe_vf "$lut_filter")
    LUT_FILTER=$(creative_unwrap_vf "$vf_safe")
    LUT_FILTER_SAFE="$vf_safe"
  fi
}

creative_pick_intro() {
  local enable="$1"
  local array_name="$2"
  INTRO_ACTIVE=0
  INTRO_SOURCE=""
  INTRO_DURATION=""
  INTRO_DESC="none"
  if [ "$enable" -ne 1 ]; then
    return
  fi
  local -n intro_array="$array_name"
  if [ ${#intro_array[@]} -eq 0 ]; then
    return
  fi
  INTRO_ACTIVE=1
  INTRO_SOURCE=$(rand_choice "$array_name")
  INTRO_DURATION=$(rand_float 1.0 2.0 2)
  INTRO_DESC="$(basename "$INTRO_SOURCE")"
  INTRO_DESC="${INTRO_DESC//,/ _}"
}

creative_apply_text_shift() {
  local base_start="$1"
  local shift="$2"
  local limit="$3"
  awk -v s="${base_start:-0}" -v d="$shift" -v l="$limit" 'BEGIN{s+=0;d+=0;l+=0;v=s+d;if(v<0)v=0;if(l>0 && v>l-0.2)v=l-0.2;if(v<0)v=0;printf "%.3f",v}'
}

creative_vignette_chain() {
  local base="$1"
  local extra="$2"
  local vignette_chain="hflip,vignette=PI/4:0.7,rotate=0.5*(PI/180):fillcolor=black"
  local vignette_safe
  vignette_safe=$(safe_vf "$vignette_chain")
  if [ -n "$extra" ]; then
    local extra_safe extra_raw
    extra_safe=$(safe_vf "$extra")
    extra_raw=$(creative_unwrap_vf "$extra_safe")
    vignette_chain="${extra_raw},${vignette_chain}"
    vignette_safe=$(safe_vf "$vignette_chain")
  fi
  CREATIVE_LAST_VF_SAFE="$vignette_safe"
  compose_vf_chain "$base" "$vignette_safe"
}
