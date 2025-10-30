#!/bin/bash

AUDIO_FILTER_PRIMARY="apulsator=mode=sine:freq=0.8"
AUDIO_FILTER_VARIANT="apulsator=mode=sine:freq=0.9"

audio_init_filter_caps() {
  AUDIO_FILTER_PRIMARY="apulsator=mode=sine:freq=0.8"
  AUDIO_FILTER_VARIANT="apulsator=mode=sine:freq=0.9"
  if ! ffmpeg_supports_filter "apulsator"; then
    AUDIO_FILTER_PRIMARY="aecho=0.8:0.9:100:0.3"
    AUDIO_FILTER_VARIANT="acompressor=threshold=-16dB:ratio=2.4"
    echo "[Audio] 'apulsator' not supported — fallback to 'aecho'."
  fi
}

apply_audio_fallback() {
  local payload="$1"
  payload="${payload//apulsator=mode=sine:freq=0.8/${AUDIO_FILTER_PRIMARY}}"
  payload="${payload//apulsator=mode=sine:freq=0.9/${AUDIO_FILTER_VARIANT}}"
  printf '%s' "$payload"
}

pick_audio_chain() {
  local roll=$(rand_int 1 100)
  AUDIO_PROFILE="resample"
  local filters=("aresample=${AUDIO_SR}")
  if [ "$roll" -le "$AUDIO_TWEAK_PROB_PERCENT" ]; then
    AUDIO_PROFILE="asetrate"
    local factor=$(rand_float 0.995 1.005 6)
    filters=("asetrate=${AUDIO_SR}*${factor}" "aresample=${AUDIO_SR}")
  elif [ "$roll" -ge 85 ]; then
    AUDIO_PROFILE="anull"
    filters=("anull" "aresample=${AUDIO_SR}")
  fi
  local tempo_target="$TEMPO_FACTOR"
  if [ "$MUSIC_VARIANT" -eq 1 ]; then
    local tempo_sign=$(rand_int 0 1)
    local tempo_delta=$(rand_float 0.010 0.030 3)
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
  # fix: ensure tempo filters keep numeric defaults
  # REGION AI: guard tempo fallbacks
  tempo_target=$(awk -v t="${tempo_target:-}" 'BEGIN{
    if (t == "" || t + 0 <= 0) {
      printf "%.6f", 1.0;
    } else {
      printf "%.6f", t + 0;
    }
  }')
  # END REGION AI
  local safe_volume=$(rand_float 0.980 1.000 4)
  safe_volume=$(awk -v v="$safe_volume" 'BEGIN{printf "%.4f", v+0}')
  local safe_rate=$(rand_float 1.0002 1.0008 7)
  local safe_tempo
  # fix: ensure tempo filters keep numeric defaults
  # REGION AI: guard safe tempo fallbacks
  safe_tempo=$(awk -v base="${tempo_target:-}" -v rate="${safe_rate:-}" 'BEGIN{
    if (base == "" || base + 0 <= 0) { base = 1.0 }
    if (rate == "" || rate + 0 <= 0) { rate = 1.0 }
    printf "%.6f", (base + 0) / (rate + 0)
  }')
  # END REGION AI
  if ffmpeg_supports_filter "highpass"; then
    AUDIO_FILTER="highpass=f=300,lowpass=f=3000"
  else
    AUDIO_FILTER=$(printf 'acompressor=threshold=-16dB:ratio=2.4,aresample=%s,atempo=1.0,volume=0.985,highpass=f=100,lowpass=f=8000' "${AUDIO_SR}")
    local fallback_note="[Audio] Fallback filter applied (highpass unavailable, switched to safe chain)"
    log_warn "$fallback_note"
    if [ -n "${logfile:-}" ]; then
      echo "$fallback_note" >>"$logfile"
    fi
  fi
  SAFE_AF_CHAIN=$(printf 'aresample=%s:resampler=soxr:precision=28:dither_method=triangular,volume=%s,afftdn=nf=-30,asetrate=%s*%s,aresample=%s,atempo=%s' "$AUDIO_SR" "$safe_volume" "$AUDIO_SR" "$safe_rate" "$AUDIO_SR" "$safe_tempo")
  AFILTER_CORE=$(IFS=,; echo "${filters[*]}")
}

audio_random_jitter_chain() {
  local sample_rate="${1:-$AUDIO_SR}" chance
  chance=$(rand_int 0 2)
  if [ "$chance" -ne 0 ]; then
    printf 'anull'
    return
  fi
  local jitter_scale
  jitter_scale=$(rand_int 0 5)
  printf 'asetrate=%s*1.%d,aresample=%s' "$sample_rate" "$jitter_scale" "$sample_rate"
}

audio_apply_combo_mode() {
  local mode="$1"
  local tempo="${2:-$TEMPO_FACTOR}"
  local sample_rate="${3:-$AUDIO_SR}"
  local chain="${AFILTER_CORE:-}"
  local profile="${AUDIO_PROFILE:-resample}"
  # REGION AI: tempo default for combo chains
  if [ -z "$tempo" ]; then
    tempo="1.0"
  fi
  # END REGION AI

  case "${mode:-}" in
    asetrate)
      chain=$(printf 'asetrate=%s*1.01,aresample=%s' "$sample_rate" "$sample_rate")
      profile="asetrate"
      ;;
    resample)
      chain=$(printf 'aresample=%s,atempo=%s' "$sample_rate" "$tempo")
      profile="resample"
      ;;
    ""|none|anull)
      ;;
    *)
      chain=$(printf 'anull,aresample=%s,%s,atempo=%s' "$sample_rate" "$AUDIO_FILTER_PRIMARY" "$tempo")
      profile="anull+jitter"
      ;;
  esac

  local jitter_chain
  jitter_chain=$(audio_random_jitter_chain "$sample_rate")
  if [ -n "$jitter_chain" ] && [ "$jitter_chain" != "anull" ]; then
    chain=$(compose_af_chain "$chain" "$jitter_chain")
    profile="${profile}+jitter"
  fi

  if [ -z "$chain" ]; then
    chain=$(printf 'aresample=%s,atempo=1.0' "$sample_rate")
  fi

  AFILTER="$(apply_audio_fallback "$chain")"
  AUDIO_PROFILE="$profile"
}

audio_codec_requires_silence() {
  local codec="$1"
  case "${codec:-none}" in
    apac|none|"" ) return 0 ;;
    * ) return 1 ;;
  esac
}

audio_guard_chain() {
  local codec="$1"
  local chain="$2"
  if audio_codec_requires_silence "$codec"; then
    printf 'anullsrc=r=%s:cl=stereo' "${AUDIO_SR:-44100}"
  else
    printf '%s' "$chain"
  fi
}

compose_af_chain() {
  local base="$1" extra="$2"
  base="$(apply_audio_fallback "$base")"
  extra="$(apply_audio_fallback "$extra")"
  # REGION AI: safe filter concatenation
  if [ -z "$extra" ]; then
    printf '%s' "$base"
    return
  fi
  if [ -z "$base" ]; then
    printf '%s' "$extra"
    return
  fi
  printf '%s,%s' "$extra" "$base"
  # END REGION AI
}
