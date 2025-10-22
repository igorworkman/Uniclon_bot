#!/bin/bash
# Core environment initialization utilities

core_init_environment() {
  local script_path="$1"

  if [ -z "$BASE_DIR" ]; then
    if [ -n "$script_path" ]; then
      BASE_DIR="$(cd "$(dirname "$script_path")" && pwd)"
    else
      BASE_DIR="$(pwd)"
    fi
  fi

  local env_bin="${BASE_DIR}/env/bin"
  if [ -d "$env_bin" ] && [[ ":$PATH:" != *":${env_bin}:"* ]]; then
    PATH="${env_bin}:${PATH}"
  fi

  CHECK_DIR="${CHECK_DIR:-${BASE_DIR}/checks}"
  OUTPUT_DIR="${OUTPUT_DIR:-output}"
  PREVIEW_DIR="${PREVIEW_DIR:-${OUTPUT_DIR}/previews}"
  TMP_ROOT="${TMP_ROOT:-${BASE_DIR}/tmp}"
  LOW_UNIQUENESS_FLAG="${LOW_UNIQUENESS_FLAG:-${CHECK_DIR}/low_uniqueness.flag}"

  export BASE_DIR CHECK_DIR OUTPUT_DIR PREVIEW_DIR TMP_ROOT LOW_UNIQUENESS_FLAG PATH

  mkdir -p "$CHECK_DIR" "$OUTPUT_DIR" "$PREVIEW_DIR" "$TMP_ROOT"
  rm -f "$LOW_UNIQUENESS_FLAG"
}

core_tmp_path() {
  printf '%s' "$TMP_ROOT"
}
