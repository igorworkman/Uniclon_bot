#!/bin/bash
# Fallback orchestration helpers

fallback_should_similarity_regen() {
  local ssim_val="$1"
  local phash_val="$2"
  if [ -z "$phash_val" ] || [ "$phash_val" = "None" ] || [ "$phash_val" = "NA" ] || [ "$phash_val" = "N/A" ]; then
    phash_val=0
  fi
  if [ -z "$ssim_val" ] || [ "$ssim_val" = "None" ] || [ "$ssim_val" = "NA" ] || [ "$ssim_val" = "N/A" ]; then
    ssim_val=0
  fi
  if awk -v v="$phash_val" 'BEGIN{exit (v+0<6?0:1)}'; then
    return 0
  fi
  if awk -v v="$ssim_val" 'BEGIN{exit (v+0>0.995?0:1)}'; then
    return 0
  fi
  return 1
}

fallback_can_retry() {
  local attempts="$1"
  local max_attempts="${2:-2}"
  if [ "$attempts" -lt "$max_attempts" ]; then
    return 0
  fi
  return 1
}

fallback_try_regen_quality() {
  ensure_run_combos
  if [ ${#QUALITY_ISSUES[@]:-0} -eq 0 ] || [ ${#QUALITY_COPY_IDS[@]:-0} -eq 0 ]; then
    return 0
  fi
  echo "⚠️ Перегенерация по качеству: ${#QUALITY_ISSUES[@]} копий"
  REGEN_OCCURRED=1
  remove_indices_for_regen "${QUALITY_ISSUES[@]}"
  REGEN_ITER=$((REGEN_ITER + 1))
  local cid
  for cid in "${QUALITY_COPY_IDS[@]}"; do
    generate_copy "$cid" "$REGEN_ITER"
  done
  return 0
}

fallback_low_uniqueness() {
  local total=${#RUN_FILES[@]}
  if [ "$total" -lt 2 ]; then
    return 1
  fi

  local idx low_ssim=0 low_phash=0 high_similarity=0
  local -a candidates=()

  for idx in "${!RUN_FILES[@]}"; do
    local ssim_val="${RUN_SSIM[$idx]:-0}"
    local phash_val="${RUN_PHASH[$idx]:-0}"
    local flag=0
    local ssim_bad=0
    local phash_bad=0
    local clone_bad=0
    if awk -v s="$ssim_val" 'BEGIN{s+=0; exit (s<0.91?0:1)}'; then
      low_ssim=$((low_ssim + 1))
      flag=1
      ssim_bad=1
    fi
    if [ "$phash_val" != "NA" ] && [ "$phash_val" != "N/A" ] && [ -n "$phash_val" ]; then
      if awk -v p="$phash_val" 'BEGIN{p+=0; exit (p<5?0:1)}'; then
        low_phash=$((low_phash + 1))
        flag=1
        phash_bad=1
      elif awk -v s="$ssim_val" -v p="$phash_val" 'BEGIN{s+=0; p+=0; exit (s>=0.995 && p<6 ? 0 : 1)}'; then
        high_similarity=$((high_similarity + 1))
        flag=1
        clone_bad=1
      fi
    fi
    if [ "$flag" -eq 1 ]; then
      local score
      score=$(awk -v s="$ssim_val" -v p="$phash_val" -v sb="$ssim_bad" -v pb="$phash_bad" -v cb="$clone_bad" 'BEGIN {
        s+=0; p+=0;
        bad_s = (sb>0 && s<0.91)?(0.91-s)*120:0;
        bad_p = (pb>0 && p<5)?(5-p)*12:0;
        near_dup = (cb>0 && s>=0.995 && p<6)?((s-0.995)*1000 + (6-p)*15):0;
        printf "%07.3f", bad_s + bad_p + near_dup;
      }')
      candidates+=("${score}|${idx}")
    fi
  done

  local trigger=1
  if [ "$high_similarity" -eq 0 ]; then
    if ! awk -v low="$low_ssim" -v total="$total" 'BEGIN{exit (low*2>total?0:1)}'; then
      if ! awk -v low="$low_phash" -v total="$total" 'BEGIN{exit (low*2>total?0:1)}'; then
        trigger=0
      fi
    fi
  fi

  if [ "$trigger" -eq 0 ] || [ "${#candidates[@]}" -eq 0 ]; then
    return 1
  fi

  local regen_count=2
  if [ "$total" -ge 3 ]; then
    regen_count=$(rand_int 2 3)
  fi
  if [ "$regen_count" -gt "$total" ]; then
    regen_count="$total"
  fi

  local selection
  selection=$(printf '%s\n' "${candidates[@]}" | sort -r)
  local -a regen_indices=()
  while IFS='|' read -r _score raw_idx; do
    [ -z "$raw_idx" ] && continue
    regen_indices+=("$raw_idx")
    if [ "${#regen_indices[@]}" -ge "$regen_count" ]; then
      break
    fi
  done <<<"$selection"

  if [ "${#regen_indices[@]}" -eq 0 ]; then
    return 1
  fi

  echo "⚠️ Low uniqueness fallback triggered. Перегенерация копий: ${#regen_indices[@]}"
  LOW_UNIQUENESS_TRIGGERED=1
  REGEN_OCCURRED=1

  local -a copy_ids=()
  for idx in "${regen_indices[@]}"; do
    copy_ids+=("$((idx + 1))")
  done

  remove_indices_for_regen "${regen_indices[@]}"

  REGEN_ITER=$((REGEN_ITER + 1))
  local sorted_ids
  sorted_ids=$(printf '%s\n' "${copy_ids[@]}" | sort -n)
  while IFS= read -r cid; do
    [ -z "$cid" ] && continue
    generate_copy "$cid" "$REGEN_ITER"
  done <<<"$sorted_ids"

  return 0
}
