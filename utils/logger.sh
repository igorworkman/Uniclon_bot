#!/bin/bash
# Logging helpers

log_info() {
  printf 'INFO: %s\n' "$*"
}

log_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

log_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

log() {
  local level="$1"
  shift || true
  case "$level" in
    INFO|info)
      log_info "$@"
      ;;
    WARN|warn|WARNING|warning)
      log_warn "$@"
      ;;
    ERROR|error|ERR|err)
      log_error "$@"
      ;;
    *)
      printf '%s: %s\n' "$level" "$*"
      ;;
  esac
}

log_restart() {
  mkdir -p output/logs
  echo "[INFO] User $(id) restarted bot at $(date)" >> output/logs/restart.log
}
