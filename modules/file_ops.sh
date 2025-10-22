#!/bin/bash
# File system helpers

ensure_dir() {
  local dir="$1"
  [ -z "$dir" ] && return 0
  mkdir -p "$dir"
}

ensure_dirs() {
  local dir
  for dir in "$@"; do
    ensure_dir "$dir"
  done
}

touch_file() {
  local target="$1"
  shift || true
  command touch "$target" "$@"
}

clear_temp() {
  local dir="${1:-$TMP_ROOT}"
  if [ -d "$dir" ]; then
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
}

file_size_bytes() {
  local size
  if size=$(stat -c %s "$1" 2>/dev/null); then
    echo "$size"
  else
    stat -f %z "$1"
  fi
}

touch_randomize_mtime() {
  local target="$1"
  local days hours minutes seconds touch_stamp
  days=$(rand_int 2 9)
  hours=$(rand_int 0 23)
  minutes=$(rand_int 0 59)
  seconds=$(rand_int 0 59)
  touch_stamp=$(format_past_timestamp "%Y%m%d%H%M.%S" "$days" "$hours" "$minutes" "$seconds")
  if [ -n "$touch_stamp" ]; then
    touch -t "$touch_stamp" "$target" 2>/dev/null || true
  fi
}
