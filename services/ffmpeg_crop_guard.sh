# shellcheck shell=bash

# Preserve any previous BASH_ENV configuration before installing the shim.
if [[ -n "${UNICLON_PREV_BASH_ENV:-}" && -f "${UNICLON_PREV_BASH_ENV}" && "${UNICLON_PREV_BASH_ENV}" != "${BASH_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${UNICLON_PREV_BASH_ENV}"
fi

# Ensure the shim is loaded only once per shell session.
if [[ -z "${UNICLON_FFMPEG_SANITIZER_LOADED:-}" ]]; then
  export UNICLON_FFMPEG_SANITIZER_LOADED=1

  ffmpeg() {
    local -a sanitized_args=()
    local arg next

    while (($#)); do
      arg="$1"
      case "$arg" in
        -vf|-filter_complex)
          shift
          if (($#)); then
            next="$1"
            local py_bin
            py_bin="${UNICLON_PYTHON:-python3}"
            local sanitized
            if ! sanitized="$(
              printf '%s' "$next" | "$py_bin" - <<'PY'
import sys
from modules.executor import fix_final_crop_chain

chain = sys.stdin.read()
print(fix_final_crop_chain(chain), end="")
PY
            )"; then
              sanitized="$next"
            fi
            sanitized_args+=("$arg" "$sanitized")
          else
            sanitized_args+=("$arg")
          fi
          ;;
        *)
          sanitized_args+=("$arg")
          ;;
      esac
      shift
    done

    command ffmpeg "${sanitized_args[@]}"
  }
fi
