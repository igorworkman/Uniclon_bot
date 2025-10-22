#!/bin/bash

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
  [ -z "$extra" ] && { printf '%s' "$base"; return; }
  [ -z "$base" ] && { printf '%s' "$extra"; return; }
  printf '%s,%s' "$base" "$extra"
}

ensure_vf_format() {
  local payload="$1"
  [ -z "$payload" ] && { printf '%s' "format=yuv420p"; return; }
  case ",${payload}," in
    *,format=yuv420p,*) printf '%s' "$payload" ;;
    *) printf '%s,format=yuv420p' "$payload" ;;
  esac
}

creative_pick_mirror() {
  local enable="$1"
  local override="$2"
  MIRROR_ACTIVE=0
  MIRROR_FILTER=""
  MIRROR_DESC="none"
  if [ -n "$override" ]; then
    if [ "$override" = "none" ]; then
      return
    fi
    MIRROR_ACTIVE=1
    MIRROR_FILTER="$override"
    MIRROR_DESC="$override"
    return
  fi
  if [ "$enable" -ne 1 ]; then
    return
  fi
  MIRROR_ACTIVE=1
  if [ "$(rand_int 0 1)" -eq 0 ]; then
    MIRROR_FILTER="hflip"
  else
    MIRROR_FILTER="vflip"
  fi
  MIRROR_DESC="$MIRROR_FILTER"
}

creative_pick_lut() {
  local enable="$1"
  local array_name="$2"
  LUT_ACTIVE=0
  LUT_FILTER=""
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
    LUT_FILTER="lut3d=file='$(escape_single_quotes "$lut_choice")':interp=tetrahedral"
  else
    LUT_DESC="curves_vintage"
    LUT_FILTER="curves=preset=vintage"
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
  if [ -n "$extra" ]; then
    vignette_chain="${extra},${vignette_chain}"
  fi
  compose_vf_chain "$base" "$vignette_chain"
}
