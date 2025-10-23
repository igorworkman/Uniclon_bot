#!/bin/bash
# Compatibility bootstrap that wires new modular layout

# Derive BASE_DIR if the caller did not export it yet. This keeps tooling that
# sources the bootstrap directly (like CI setup steps) self-sufficient.
if [ -z "${BASE_DIR:-}" ]; then
  BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

ensure_script_permissions() {
  local modules_dir="${BASE_DIR}/modules"
  if compgen -G "${modules_dir}/"'*.sh' >/dev/null; then
    chmod +x "${modules_dir}"/*.sh
  fi

  local main_script="${BASE_DIR}/process_protective_v1.6.sh"
  if [ -f "${main_script}" ]; then
    chmod +x "${main_script}"
  fi
}

ensure_script_permissions

MODULES_DIR="${BASE_DIR}/modules"
source "${MODULES_DIR}/_index.sh"

bootstrap_init() {
  local script_path="$1"
  core_init_environment "$script_path"
}

uuid_gen_short() {
  uuid_gen | cut -c1-8
}

build_report() {
  report_builder_finalize "$@"
}

write_manifest() {
  manifest_write_entry "$@"
}
