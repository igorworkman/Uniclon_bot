#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$ROOT_DIR"
source "${ROOT_DIR}/bootstrap_compat.sh"
bootstrap_init "${ROOT_DIR}/process_protective_v1.6.sh"

required_functions=(
  random_seed rand_between rand_bool rng_next_chunk rand_choice rand_float rand_uint32
  clip_start duration timestamp_offset ffmpeg_time_to_seconds
  ensure_dir ensure_dirs touch_file clear_temp file_size_bytes touch_randomize_mtime
  log_info log_warn log_error log
  parse_args clamp uuid_gen exec_with_retry check_exit
)

missing=()
for fn in "${required_functions[@]}"; do
  if ! declare -F "$fn" >/dev/null; then
    missing+=("$fn")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  printf 'Missing bindings: %s\n' "${missing[*]}" >&2
  exit 1
fi

echo "All module bindings are available."
