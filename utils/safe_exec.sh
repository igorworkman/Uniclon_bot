#!/bin/bash
# Safe execution helpers

exec_with_retry() {
  local attempts="$1"
  shift
  local delay="${1:-1}"
  shift || true
  local cmd=("$@")

  local try=1
  while :; do
    "${cmd[@]}" && return 0
    local status=$?
    if [ "$try" -ge "$attempts" ]; then
      return "$status"
    fi
    sleep "$delay"
    try=$((try + 1))
  done
}

check_exit() {
  local status="$1"
  local message="$2"
  if [ "$status" -ne 0 ]; then
    log_error "$message"
    exit "$status"
  fi
}
