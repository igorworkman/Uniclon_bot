#!/bin/bash
# Deterministic RNG helpers

RNG_HEX=""
RNG_POS=0

random_seed() {
  RNG_HEX="$1"
  RNG_POS=0
}

init_rng() {
  random_seed "$1"
}

deterministic_md5() {
  if command -v md5 >/dev/null 2>&1; then
    printf "%s" "$1" | md5 | tr -d ' \t\n' | tail -c 32
  else
    printf "%s" "$1" | md5sum | awk '{print $1}'
  fi
}

rng_next_chunk() {
  if [ ${#RNG_HEX} -lt 4 ] || [ $((RNG_POS + 4)) -gt ${#RNG_HEX} ]; then
    RNG_HEX="$(deterministic_md5 "${RNG_HEX}_${RNG_POS}")"
    RNG_POS=0
  fi
  local chunk="${RNG_HEX:$RNG_POS:4}"
  RNG_POS=$((RNG_POS + 4))
  printf "%d" $((16#$chunk))
}

rand_between() {
  if [ $# -lt 2 ]; then
    printf "rand_between requires two arguments\n" >&2
    return 1
  fi

  local A="$1"
  local B="$2"
  local span raw

  span=$((B - A + 1))
  raw=$(rng_next_chunk)
  echo $((A + raw % span))
}

rand_int() {
  rand_between "$@"
}

rand_choice() {
  local arrname=$1[@]
  local arr=("${!arrname}")
  local idx=$(( $(rng_next_chunk) % ${#arr[@]} ))
  echo "${arr[$idx]}"
}

rand_float() {
  local MIN="$1" MAX="$2" SCALE="$3"
  local raw=$(rng_next_chunk)
  awk -v min="$MIN" -v max="$MAX" -v r="$raw" -v scale="$SCALE" 'BEGIN {s=r/65535; printf "%.*f", scale, min + s*(max-min)}'
}

rand_uint32() {
  local hi=$(rng_next_chunk)
  local lo=$(rng_next_chunk)
  echo $(( (hi << 16) | lo ))
}

rand_bool() {
  if [ "$(rand_between 0 1)" -eq 0 ]; then
    echo 0
  else
    echo 1
  fi
}
