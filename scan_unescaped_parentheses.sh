#!/bin/bash
# Скрипт для поиска неэкранированных скобок в Bash-строках (bash -c / eval)
# Цель: найти все места, где могут возникнуть ошибки вида:
# "syntax error near unexpected token '('"

echo "🔍 Анализ репозитория на неэкранированные скобки..."

# Ограничим поиск на bash-скрипты и core/init файлы
find . -type f \( -name "*.sh" -o -name "*.bash" \) | while read -r file; do
  # Проверка только строк, содержащих возможное выполнение динамических команд
  grep -HnE 'bash -c|eval|ffmpeg.*\(.*\)|CUR_VF_EXTRA|CUR_AF_EXTRA' "$file" \
    | grep -E '\(|\)' \
    | grep -v '\\(' \
    | grep -v '#'
done > potential_parentheses_issues.log

if [ -s potential_parentheses_issues.log ]; then
  echo "⚠️ Найдены потенциально опасные участки:"
  cat potential_parentheses_issues.log
  echo ""
  echo "📂 Сохранено в: potential_parentheses_issues.log"
else
  echo "✅ Потенциальных проблем с неэкранированными скобками не найдено."
fi
