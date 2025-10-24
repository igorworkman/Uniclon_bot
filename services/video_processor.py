import logging
import subprocess
import time
from pathlib import Path

from config import BASE_DIR, OUTPUT_DIR as CONFIG_OUTPUT_DIR, SCRIPT_PATH as CONFIG_SCRIPT_PATH

logger = logging.getLogger(__name__)

# REGION AI: protective script paths
_SCRIPT_PATH = Path(CONFIG_SCRIPT_PATH).resolve()
PROJECT_DIR = _SCRIPT_PATH.parent
OUTPUT_DIR = CONFIG_OUTPUT_DIR
# END REGION AI


# REGION AI: synchronous protective runner
def run_protective_process(
    filename: str,
    copies: int,
    profile: str = "",
    quality: str = "",
) -> bool:
    if copies < 1:
        raise ValueError("copies must be >= 1")
    full_path = (BASE_DIR / filename).resolve()
    if not full_path.exists():
        logger.error("❌ Файл не найден: %s", full_path)
        return False
    if not _SCRIPT_PATH.exists():
        logger.error("❌ Script not found: %s", _SCRIPT_PATH)
        return False
    try:
        mode = _SCRIPT_PATH.stat().st_mode
        if not mode & 0o111:
            _SCRIPT_PATH.chmod(mode | 0o111)
    except OSError:
        logger.debug("Failed to ensure executable for %s", _SCRIPT_PATH, exc_info=True)
    cmd = [str(_SCRIPT_PATH), str(full_path), str(int(copies))]
    start_ts = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        logger.error("❌ Unable to execute %s", _SCRIPT_PATH, exc_info=True)
        return False
    except OSError as exc:
        logger.error("❌ Failed to spawn process_protective_v1.6.sh: %s", exc)
        return False
    duration = time.monotonic() - start_ts
    stdout, stderr = proc.stdout or "", proc.stderr or ""
    if proc.returncode != 0:
        logger.error(
            "⚠️ Скрипт завершился с кодом %s: %s",
            proc.returncode,
            (stderr or stdout).strip() or "no output",
        )
        return False
    if stdout:
        logger.info("process_protective stdout:\n%s", stdout.rstrip())
    if stderr:
        logger.warning("process_protective stderr:\n%s", stderr.rstrip())
    logger.info("✅ Скрипт успешно завершён: %s (%.2fs)", full_path, duration)
    logger.info("📂 Готовые файлы доступны в %s", OUTPUT_DIR)
    return True
# END REGION AI
