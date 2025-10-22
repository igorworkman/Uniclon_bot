#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$ROOT_DIR"

# Syntax check for key scripts
bash -n "${ROOT_DIR}/process_protective_v1.6.sh"
for file in ${ROOT_DIR}/modules/*.sh ${ROOT_DIR}/utils/*.sh ${ROOT_DIR}/bootstrap_compat.sh; do
  [ -e "$file" ] || continue
  bash -n "$file"
done

source "${ROOT_DIR}/bootstrap_compat.sh"
bootstrap_init "${ROOT_DIR}/process_protective_v1.6.sh"

random_seed "1a2b3c4d"
rand_between 0 10 >/dev/null
rand_bool >/dev/null

local_clip_start=$(clip_start "00:00:02.000" "0.000" "clip_start" "verify")
local_duration=$(duration "5.000" "0.500" "duration" "verify")
[ -n "$local_clip_start" ] && [ -n "$local_duration" ]

test_uuid=$(uuid_gen)
[ ${#test_uuid} -gt 0 ]

exec_with_retry 2 0.1 true
check_exit 0 "noop"

parse_args --debug >/dev/null || true

log_info "Modular environment verified"

echo "verify_modular_env.sh — all checks passed"
