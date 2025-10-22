#!/bin/bash
# Generic helpers

clamp() {
  local value="$1"
  local min="$2"
  local max="$3"
  if (( value < min )); then
    echo "$min"
  elif (( value > max )); then
    echo "$max"
  else
    echo "$value"
  fi
}

uuid_gen() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4().hex)
PY
  fi
}

parse_args() {
  POSITIONAL_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --debug)
        DEBUG=1
        ;;
      --music-variant)
        MUSIC_VARIANT=1
        ;;
      --profile)
        if [ -z "${2:-}" ]; then
          echo "❌ --profile требует значение" >&2
          return 1
        fi
        PROFILE=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
        shift
        ;;
      --qt-meta)
        QT_META=1
        ;;
      --no-qt-meta)
        QT_META=0
        ;;
      --strict-clean)
        STRICT_CLEAN=1
        QT_META=0
        ;;
      --quality)
        if [ -z "${2:-}" ]; then
          echo "❌ --quality требует значение" >&2
          return 1
        fi
        QUALITY=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
        case "$QUALITY" in
          high|std)
            ;;
          *)
            echo "❌ Неизвестное качество: $2" >&2
            return 1
            ;;
        esac
        shift
        ;;
      --auto-clean)
        AUTO_CLEAN=1
        ;;
      --mirror)
        ENABLE_MIRROR=1
        ;;
      --intro)
        ENABLE_INTRO=1
        ;;
      --lut)
        ENABLE_LUT=1
        ;;
      --no-device-info)
        DEVICE_INFO=0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        ;;
    esac
    shift
  done
  return 0
}
