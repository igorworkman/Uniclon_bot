#!/bin/bash
# Compatibility bootstrap that wires new modular layout

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
