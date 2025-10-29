import logging
import re
import subprocess
import time
from pathlib import Path

from config import BASE_DIR

logger = logging.getLogger(__name__)

# REGION AI: protective script paths
PROJECT_DIR = Path("/Users/teddy/Documents/Uniclon_bot")
OUTPUT_DIR = PROJECT_DIR / "output"
_SCRIPT_PATH = (PROJECT_DIR / "process_protective_v1.6.sh").resolve()
# END REGION AI


# REGION AI: synchronous protective runner
def run_protective_process(
    filename: str,
    copies: int,
    profile: str = "",
    quality: str = "",
) -> dict:
    if copies < 1:
        raise ValueError("copies must be >= 1")
    full_path = (BASE_DIR / filename).resolve()
    if not full_path.exists():
        logger.error("❌ Файл не найден: %s", full_path)
        return {
            "success_count": 0,
            "failed_count": copies,
            "temp_fail": False,
            "temp_error_count": 0,
            "log_tail": f"File not found: {full_path}",
        }
    if not _SCRIPT_PATH.exists():
        logger.error("❌ Script not found: %s", _SCRIPT_PATH)
        return {
            "success_count": 0,
            "failed_count": copies,
            "temp_fail": False,
            "temp_error_count": 0,
            "log_tail": f"Script not found: {_SCRIPT_PATH}",
        }

    
    def _invoke(requested: int) -> dict:
        try:
            mode = _SCRIPT_PATH.stat().st_mode
            if not mode & 0o111:
                _SCRIPT_PATH.chmod(mode | 0o111)
        except OSError:
            logger.debug("Failed to ensure executable for %s", _SCRIPT_PATH, exc_info=True)
        cmd = ["./process_protective_v1.6.sh", str(full_path), str(int(requested))]
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
            return {
                "success_count": 0,
                "failed_count": requested,
                "temp_fail": False,
                "temp_error_count": 0,
                "log_tail": f"Unable to execute {_SCRIPT_PATH}",
                "fatal": True,
            }
        except OSError as exc:
            logger.error("❌ Failed to spawn process_protective_v1.6.sh: %s", exc)
            return {
                "success_count": 0,
                "failed_count": requested,
                "temp_fail": False,
                "temp_error_count": 0,
                "log_tail": str(exc),
                "fatal": True,
            }
        duration = time.monotonic() - start_ts
        stdout, stderr = proc.stdout or "", proc.stderr or ""
        combined = "\n".join([part for part in (stdout, stderr) if part])
        lines = combined.splitlines()
        tail20 = "\n".join(lines[-20:]) if lines else combined
        success_count = len(re.findall(r"Generated copy #\\d+", combined))
        failed_count = len(re.findall(r"Failed copy #\\d+", combined))
        temp_fail = False
        fatal = False
        if proc.returncode != 0:
            tail10 = "\n".join(lines[-10:]) if lines else combined
            temp_fail = any(
                marker in tail10
                for marker in (
                    "[WARN] Uniqueness low but accepted",
                    "[Fallback] Copy",
                )

    try:
        mode = _SCRIPT_PATH.stat().st_mode
        if not mode & 0o111:
            _SCRIPT_PATH.chmod(mode | 0o111)
    except OSError:
        logger.debug("Failed to ensure executable for %s", _SCRIPT_PATH, exc_info=True)
    cmd = ["./process_protective_v1.6.sh", str(full_path), str(int(copies))]
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
        return {
            "success_count": 0,
            "failed_count": copies,
            "temp_fail": False,
            "log_tail": f"Unable to execute {_SCRIPT_PATH}",
        }
    except OSError as exc:
        logger.error("❌ Failed to spawn process_protective_v1.6.sh: %s", exc)
        return {
            "success_count": 0,
            "failed_count": copies,
            "temp_fail": False,
            "log_tail": str(exc),
        }
    duration = time.monotonic() - start_ts
    stdout, stderr = proc.stdout or "", proc.stderr or ""
    combined = "\n".join([part for part in (stdout, stderr) if part])
    lines = combined.splitlines()
    tail20 = "\n".join(lines[-20:]) if lines else combined
    success_count = len(re.findall(r"Generated copy #\\d+", combined))
    failed_count = len(re.findall(r"Failed copy #\\d+", combined))
    warn_markers = (
        "[WARN] Uniqueness low but accepted",
        "[Fallback] Copy",
    )
    temp_fail = any(marker in combined for marker in warn_markers)
    if proc.returncode != 0:
        tail10 = "\n".join(lines[-10:]) if lines else combined
        if temp_fail:
            logger.warning(
                "⚠️ Зафиксирована временная ошибка (rc=%s).", proc.returncode

            )
            if temp_fail:
                logger.warning(
                    "⚠️ Зафиксирована временная ошибка (rc=%s).",
                    proc.returncode,
                )
            else:
                fatal = True
                logger.error(
                    "⚠️ Скрипт завершился с кодом %s: %s",
                    proc.returncode,
                    (stderr or stdout).strip() or "no output",
                )
        else:

            if stdout:
                logger.info("process_protective stdout:\n%s", stdout.rstrip())
            if stderr:
                logger.warning("process_protective stderr:\n%s", stderr.rstrip())
            logger.info("✅ Скрипт успешно завершён: %s (%.2fs)", full_path, duration)
            logger.info("📂 Готовые файлы доступны в %s", OUTPUT_DIR)
        if not tail20.strip():
            tail20 = (stderr or stdout).strip() or f"Process exited with code {proc.returncode}"
        remaining_failed = max(0, requested - success_count)
        return {
            "success_count": success_count,
            "failed_count": failed_count or remaining_failed,
            "temp_fail": temp_fail,
            "temp_error_count": remaining_failed if temp_fail else 0,
            "log_tail": tail20,
            "fatal": fatal,
        }

    total_success = 0
    fatal_error = False
    log_tail_parts = []
    while total_success < copies and not fatal_error:
        requested = copies - total_success
        result = _invoke(requested)
        total_success += result["success_count"]
        fatal_error = result.get("fatal", False)
        log_tail_parts.append(result.get("log_tail", ""))
        if not result.get("temp_fail"):
            break
        if result["success_count"] == 0:
            break

    failed_total = max(0, copies - total_success)
    final_tail = "\n---\n".join([tail for tail in log_tail_parts if tail])

            logger.error(
                "⚠️ Скрипт завершился с кодом %s: %s",
                proc.returncode,
                (stderr or stdout).strip() or "no output",
            )
    else:
        if stdout:
            logger.info("process_protective stdout:\n%s", stdout.rstrip())
        if stderr:
            logger.warning("process_protective stderr:\n%s", stderr.rstrip())
        if temp_fail:
            logger.warning("⚠️ Скрипт сообщил о временных проблемах уникальности.")
        logger.info("✅ Скрипт успешно завершён: %s (%.2fs)", full_path, duration)
        logger.info("📂 Готовые файлы доступны в %s", OUTPUT_DIR)
    if not tail20.strip():
        tail20 = (stderr or stdout).strip() or f"Process exited with code {proc.returncode}"

    return {
        "success_count": total_success,
        "failed_count": failed_total,
        "temp_fail": failed_total > 0,
        "temp_error_count": failed_total,
        "log_tail": final_tail,
    }
# END REGION AI
