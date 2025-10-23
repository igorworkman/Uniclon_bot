#!/bin/bash

apply_combo_context() {
  local combo_string="$1"
  local combo_dump="" combo_script="" status=0 var
  local combo_print="$combo_string"
  if [[ "$combo_string" == *"CUR_VF_EXTRA"* ]]; then
    combo_print="${combo_print//\\(/(}"
    combo_print="${combo_print//\\)/)}"
    combo_print="${combo_print//(/\\(}"
    combo_print="${combo_print//)/\\)}"
  fi
  combo_script=$(mktemp "${TMP_ROOT:-/tmp}/combo_ctx.XXXXXX") || return 1
  {
    printf 'set -euo pipefail\n'
    declare -f
    while IFS= read -r var; do
      case "$var" in
        BASHOPTS|BASHPID|BASH_ARGC|BASH_ARGV|BASH_LINENO|BASH_SOURCE|BASH_VERSINFO|DIRSTACK|EUID|FUNCNAME|GROUPS|LINENO|PIPESTATUS|PPID|RANDOM|SECONDS|SHELLOPTS|UID)
          continue
          ;;
      esac
      [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
      if declare -p "$var" >/dev/null 2>&1; then
        declare -p "$var"
      fi
    done < <(compgen -A variable)
    printf '%s\n' "$combo_print"
    printf '%s\n' "for var in CUR_COMBO_LABEL CFPS CNOISE CMIRROR CAUDIO CSHIFT CBR CSOFT CLEVEL CUR_VF_EXTRA CUR_AF_EXTRA; do printf '%s\\t%s\\n' \"\$var\" \"\${!var}\"; done"
  } >"$combo_script"
  combo_dump=$(bash --noprofile --norc "$combo_script")
  status=$?
  rm -f "$combo_script"
  (( status == 0 )) || return 1
  local key value
  while IFS=$'\t' read -r key value; do
    case "$key" in
      CUR_COMBO_LABEL|CFPS|CNOISE|CMIRROR|CAUDIO|CSHIFT|CBR|CSOFT|CLEVEL|CUR_VF_EXTRA|CUR_AF_EXTRA)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <<<"$combo_dump"
  return 0
}

variant_max_share() {
  local -n arr="$1"
  local total=${#arr[@]}
  if [ "$total" -eq 0 ]; then
    echo "0"
    return
  fi
  printf '%s\n' "${arr[@]}" | awk -v total="$total" '
    NF==0 {next}
    {count[$0]++}
    END {
      max=0
      for (k in count) {
        if (count[k] > max) {
          max = count[k]
        }
      }
      if (total > 0) {
        printf "%.4f", max/total
      } else {
        printf "0"
      }
    }
  '
}

duplicate_threshold() {
  local total="$1"
  if [ "$total" -ge 10 ]; then
    echo 4
  elif [ "$total" -ge 6 ]; then
    echo 3
  else
    echo 2
  fi
}

calculate_duplicate_max() {
  local -n fps_arr="$1"
  local -n br_arr="$2"
  local -n dur_arr="$3"
  local -a seen_keys=()
  local -a seen_counts=()
  local max_count=0
  local total=${#fps_arr[@]}
  local idx=0
  while [ "$idx" -lt "$total" ]; do
    local fps_val="${fps_arr[$idx]}"
    local br_val="${br_arr[$idx]}"
    local dur_val="${dur_arr[$idx]}"
    local key="${fps_val}|${br_val}|$(duration_bucket "$dur_val")"
    local found=0
    local current=0
    local list_idx=0
    while [ "$list_idx" -lt "${#seen_keys[@]}" ]; do
      if [ "${seen_keys[$list_idx]}" = "$key" ]; then
        current=$(( ${seen_counts[$list_idx]} + 1 ))
        seen_counts[$list_idx]=$current
        found=1
        break
      fi
      list_idx=$((list_idx + 1))
    done
    if [ "$found" -eq 0 ]; then
      seen_keys+=("$key")
      current=1
      seen_counts+=("$current")
    fi
    if [ "$current" -gt "$max_count" ]; then
      max_count=$current
    fi
    idx=$((idx + 1))
  done
  echo "$max_count"
}

remove_last_generated() {
  local remove_count="$1"
  for ((drop=0; drop<remove_count; drop++)); do
    local idx=$(( ${#RUN_FILES[@]} - 1 ))
    [ "$idx" -lt 0 ] && break
    local combo_key="${RUN_SOFTWARES[$idx]}|${RUN_ENCODERS[$idx]}"
    unmark_combo_key "$combo_key"
    local variant_key="${RUN_VARIANT_KEYS[$idx]:-}"
    if [ -n "$variant_key" ]; then
      unmark_variant_key "$variant_key"
    fi
    local file_path="${OUTPUT_DIR}/${RUN_FILES[$idx]}"
    local preview_file="${RUN_PREVIEWS[$idx]:-}"
    rm -f "$file_path" 2>/dev/null || true
    if [ -n "$preview_file" ]; then
      rm -f "${OUTPUT_DIR}/${preview_file}" 2>/dev/null || true
    fi
    RUN_FILES=("${RUN_FILES[@]:0:$idx}")
    RUN_BITRATES=("${RUN_BITRATES[@]:0:$idx}")
    RUN_FPS=("${RUN_FPS[@]:0:$idx}")
    RUN_DURATIONS=("${RUN_DURATIONS[@]:0:$idx}")
    RUN_SIZES=("${RUN_SIZES[@]:0:$idx}")
    RUN_ENCODERS=("${RUN_ENCODERS[@]:0:$idx}")
    RUN_SOFTWARES=("${RUN_SOFTWARES[@]:0:$idx}")
    RUN_CREATION_TIMES=("${RUN_CREATION_TIMES[@]:0:$idx}")
    RUN_SEEDS=("${RUN_SEEDS[@]:0:$idx}")
    RUN_TARGET_DURS=("${RUN_TARGET_DURS[@]:0:$idx}")
    RUN_TARGET_BRS=("${RUN_TARGET_BRS[@]:0:$idx}")
    RUN_COMBO_HISTORY=("${RUN_COMBO_HISTORY[@]:0:$idx}")
    RUN_PROFILES=("${RUN_PROFILES[@]:0:$idx}")
    RUN_QUALITIES=("${RUN_QUALITIES[@]:0:$idx}")
    RUN_FALLBACK_REASON=("${RUN_FALLBACK_REASON[@]:0:$idx}")
    RUN_COMBO_USED=("${RUN_COMBO_USED[@]:0:$idx}")
    RUN_ATTEMPTS=("${RUN_ATTEMPTS[@]:0:$idx}")
    RUN_QT_MAKES=("${RUN_QT_MAKES[@]:0:$idx}")
    RUN_QT_MODELS=("${RUN_QT_MODELS[@]:0:$idx}")
    RUN_QT_SOFTWARES=("${RUN_QT_SOFTWARES[@]:0:$idx}")
    RUN_SSIM=("${RUN_SSIM[@]:0:$idx}")
    RUN_PSNR=("${RUN_PSNR[@]:0:$idx}")
    RUN_PHASH=("${RUN_PHASH[@]:0:$idx}")
    RUN_UNIQ=("${RUN_UNIQ[@]:0:$idx}")
    RUN_QPASS=("${RUN_QPASS[@]:0:$idx}")
    RUN_CREATIVE_MIRROR=("${RUN_CREATIVE_MIRROR[@]:0:$idx}")
    RUN_CREATIVE_INTRO=("${RUN_CREATIVE_INTRO[@]:0:$idx}")
    RUN_CREATIVE_LUT=("${RUN_CREATIVE_LUT[@]:0:$idx}")
    RUN_PREVIEWS=("${RUN_PREVIEWS[@]:0:$idx}")
    if [ ${#LAST_COMBOS[@]} -gt 0 ]; then
      LAST_COMBOS=("${LAST_COMBOS[@]:0:${#LAST_COMBOS[@]}-1}")
    fi
  done
}

remove_indices_for_regen() {
  local indices=("$@")
  [ "${#indices[@]}" -eq 0 ] && return
  local sorted
  sorted=$(printf '%s\n' "${indices[@]}" | sort -rn)
  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    [ "$idx" -lt 0 ] && continue
    if [ "$idx" -ge "${#RUN_FILES[@]}" ]; then
      continue
    fi
    local combo_key="${RUN_SOFTWARES[$idx]}|${RUN_ENCODERS[$idx]}"
    unmark_combo_key "$combo_key"
    rm -f "${OUTPUT_DIR}/${RUN_FILES[$idx]}" 2>/dev/null || true
    if [ -n "${RUN_PREVIEWS[$idx]:-}" ]; then
      rm -f "${OUTPUT_DIR}/${RUN_PREVIEWS[$idx]}" 2>/dev/null || true
    fi
    RUN_FILES=("${RUN_FILES[@]:0:$idx}" "${RUN_FILES[@]:$((idx + 1))}")
    RUN_BITRATES=("${RUN_BITRATES[@]:0:$idx}" "${RUN_BITRATES[@]:$((idx + 1))}")
    RUN_FPS=("${RUN_FPS[@]:0:$idx}" "${RUN_FPS[@]:$((idx + 1))}")
    RUN_DURATIONS=("${RUN_DURATIONS[@]:0:$idx}" "${RUN_DURATIONS[@]:$((idx + 1))}")
    RUN_SIZES=("${RUN_SIZES[@]:0:$idx}" "${RUN_SIZES[@]:$((idx + 1))}")
    RUN_ENCODERS=("${RUN_ENCODERS[@]:0:$idx}" "${RUN_ENCODERS[@]:$((idx + 1))}")
    RUN_SOFTWARES=("${RUN_SOFTWARES[@]:0:$idx}" "${RUN_SOFTWARES[@]:$((idx + 1))}")
    RUN_CREATION_TIMES=("${RUN_CREATION_TIMES[@]:0:$idx}" "${RUN_CREATION_TIMES[@]:$((idx + 1))}")
    RUN_SEEDS=("${RUN_SEEDS[@]:0:$idx}" "${RUN_SEEDS[@]:$((idx + 1))}")
    RUN_TARGET_DURS=("${RUN_TARGET_DURS[@]:0:$idx}" "${RUN_TARGET_DURS[@]:$((idx + 1))}")
    RUN_TARGET_BRS=("${RUN_TARGET_BRS[@]:0:$idx}" "${RUN_TARGET_BRS[@]:$((idx + 1))}")
    RUN_COMBO_HISTORY=("${RUN_COMBO_HISTORY[@]:0:$idx}" "${RUN_COMBO_HISTORY[@]:$((idx + 1))}")
    RUN_PROFILES=("${RUN_PROFILES[@]:0:$idx}" "${RUN_PROFILES[@]:$((idx + 1))}")
    RUN_QUALITIES=("${RUN_QUALITIES[@]:0:$idx}" "${RUN_QUALITIES[@]:$((idx + 1))}")
    RUN_FALLBACK_REASON=("${RUN_FALLBACK_REASON[@]:0:$idx}" "${RUN_FALLBACK_REASON[@]:$((idx + 1))}")
    RUN_COMBO_USED=("${RUN_COMBO_USED[@]:0:$idx}" "${RUN_COMBO_USED[@]:$((idx + 1))}")
    RUN_ATTEMPTS=("${RUN_ATTEMPTS[@]:0:$idx}" "${RUN_ATTEMPTS[@]:$((idx + 1))}")
    RUN_QT_MAKES=("${RUN_QT_MAKES[@]:0:$idx}" "${RUN_QT_MAKES[@]:$((idx + 1))}")
    RUN_QT_MODELS=("${RUN_QT_MODELS[@]:0:$idx}" "${RUN_QT_MODELS[@]:$((idx + 1))}")
    RUN_QT_SOFTWARES=("${RUN_QT_SOFTWARES[@]:0:$idx}" "${RUN_QT_SOFTWARES[@]:$((idx + 1))}")
    RUN_SSIM=("${RUN_SSIM[@]:0:$idx}" "${RUN_SSIM[@]:$((idx + 1))}")
    RUN_PSNR=("${RUN_PSNR[@]:0:$idx}" "${RUN_PSNR[@]:$((idx + 1))}")
    RUN_PHASH=("${RUN_PHASH[@]:0:$idx}" "${RUN_PHASH[@]:$((idx + 1))}")
    RUN_UNIQ=("${RUN_UNIQ[@]:0:$idx}" "${RUN_UNIQ[@]:$((idx + 1))}")
    RUN_QPASS=("${RUN_QPASS[@]:0:$idx}" "${RUN_QPASS[@]:$((idx + 1))}")
    RUN_CREATIVE_MIRROR=("${RUN_CREATIVE_MIRROR[@]:0:$idx}" "${RUN_CREATIVE_MIRROR[@]:$((idx + 1))}")
    RUN_CREATIVE_INTRO=("${RUN_CREATIVE_INTRO[@]:0:$idx}" "${RUN_CREATIVE_INTRO[@]:$((idx + 1))}")
    RUN_CREATIVE_LUT=("${RUN_CREATIVE_LUT[@]:0:$idx}" "${RUN_CREATIVE_LUT[@]:$((idx + 1))}")
    RUN_PREVIEWS=("${RUN_PREVIEWS[@]:0:$idx}" "${RUN_PREVIEWS[@]:$((idx + 1))}")
    RUN_VARIANT_KEYS=("${RUN_VARIANT_KEYS[@]:0:$idx}" "${RUN_VARIANT_KEYS[@]:$((idx + 1))}")
  done <<<"$sorted"
  LAST_COMBOS=()
  if [ "${#RUN_COMBO_HISTORY[@]:-0}" -gt 0 ]; then
    for combo in "${RUN_COMBO_HISTORY[@]}"; do
      LAST_COMBOS+=("$combo")
    done
  fi
}
