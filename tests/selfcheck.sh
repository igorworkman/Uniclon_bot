#!/bin/bash
# tests/selfcheck.sh — базовый тест целостности Uniclon
echo "[TEST] Launching Uniclon self-check..."
bash process_protective_v1.6.sh "tests/sample.mp4" 1 --dry-run >/tmp/uniclon_test.log 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  echo "❌ FAIL: script exited with code $RC"
  tail -n 10 /tmp/uniclon_test.log
  exit 1
fi
echo "✅ PASS: Uniclon pipeline stable"
