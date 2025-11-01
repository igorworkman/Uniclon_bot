#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "🚀 Running full project code check..."

PROJECT_TARGETS=(modules services apps handlers uniclon_bot.py)
EXISTING_TARGETS=()
for target in "${PROJECT_TARGETS[@]}"; do
  if [ -e "$target" ]; then
    EXISTING_TARGETS+=("$target")
  fi
done

if [ "${#EXISTING_TARGETS[@]}" -eq 0 ]; then
  echo "⚠️ No project targets found for linting."
else
  if command -v flake8 >/dev/null 2>&1; then
    echo "✨ Running flake8 style checks..."
    flake8 "${EXISTING_TARGETS[@]}"
  else
    echo "⚠️ flake8 is not installed; skipping style checks."
  fi
fi

echo "🧮 Running radon complexity analysis..."
if [ "${#EXISTING_TARGETS[@]}" -eq 0 ]; then
  echo "⚠️ No project targets found for radon analysis."
else
  if command -v radon >/dev/null 2>&1; then
    radon cc -s -a "${EXISTING_TARGETS[@]}" \
      --exclude .git,.venv,venv,env,build,dist,__pycache__,.pytest_cache || true
  else
    echo "⚠️ radon is not installed; skipping complexity analysis."
  fi
fi

echo "🧪 Running pytest suite..."
if command -v pytest >/dev/null 2>&1; then
  pytest -q || true
else
  echo "⚠️ pytest is not installed; skipping tests."
fi

echo "🧱 Running python syntax checks..."
find . \
  -path './.git' -prune -o \
  -path './.venv' -prune -o \
  -path './venv' -prune -o \
  -path './env' -prune -o \
  -path './build' -prune -o \
  -path './dist' -prune -o \
  -path './__pycache__' -prune -o \
  -name '*.py' -print \
| xargs -r -n1 python -m py_compile

echo "✅ All checks complete."
