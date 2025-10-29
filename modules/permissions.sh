#!/bin/bash
set -e

# Определяем базовую директорию проекта
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"

# Устанавливаем права на выполнение для основного скрипта и всех модулей
chmod +x "$BASE_DIR/process_protective_v1.6.sh"
chmod +x "$BASE_DIR"/modules/*.sh

echo "[OK] Permissions set for all modules."

