#!/bin/bash
set -euo pipefail
# REGION AI: comprehensive project check script
# 🧪 Uniclon Bot — Полная проверка проекта
# Автор: GPT-S JFB PRO v2.1
# Назначение: Комплексная проверка синтаксиса, импортов, зависимостей, стиля и тестов.

echo "🚀 Запуск полной проверки Uniclon_bot"
echo "-------------------------------------"

# Проверка Python синтаксиса
echo "1️⃣ Проверка синтаксиса Python..."
find . -name "*.py" -not -path "./venv/*" -exec python3 -m py_compile {} \; || exit 1

# Проверка bash скриптов
echo "2️⃣ Проверка bash-скриптов..."
find . -name "*.sh" -exec bash -n {} \; || exit 1

# Проверка зависимостей
echo "3️⃣ Проверка зависимостей..."
if ! python3 -m pip check; then
    echo "❌ Проверка зависимостей не пройдена" >&2
    exit 1
fi

# Проверка неиспользуемого кода
echo "4️⃣ Анализ импортов и неиспользуемых функций..."
if ! command -v vulture &> /dev/null; then pip install vulture -q; fi
vulture . --min-confidence 80

# Проверка типов (mypy)
echo "5️⃣ Проверка типов (mypy)..."
if ! command -v mypy &> /dev/null; then pip install mypy -q; fi
if ! mypy . --ignore-missing-imports; then
    echo "❌ Проверка типов (mypy) завершилась с ошибками" >&2
    exit 1
fi

# Проверка стиля и логики
echo "6️⃣ Проверка кода (pylint)..."
if ! command -v pylint &> /dev/null; then pip install pylint -q; fi
pylint --exit-zero $(find . -name "*.py" -not -path "./venv/*")

# Проверка форматирования
echo "7️⃣ Проверка стиля (flake8)..."
if ! command -v flake8 &> /dev/null; then pip install flake8 -q; fi
flake8 . --exclude venv --max-line-length=120

# Проверка сложности
echo "8️⃣ Проверка дублирующего кода (radon)..."
if ! command -v radon &> /dev/null; then pip install radon -q; fi
radon cc . -s -a

# Проверка тестов (pytest)
if [ -d "tests" ]; then
    echo "9️⃣ Запуск тестов..."
    if ! command -v pytest &> /dev/null; then pip install pytest -q; fi
    pytest -v --maxfail=1 --disable-warnings
else
    echo "⚠️ Каталог tests/ не найден — тесты пропущены"
fi

# END REGION AI
echo "-------------------------------------"
echo "✅ Проверка завершена. Смотри отчёт выше."
