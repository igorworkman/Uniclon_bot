import logging
import subprocess
import time
from config import BASE_DIR

logger = logging.getLogger(__name__)
_SCRIPT_PATH = (BASE_DIR / "process_protective_v1.6.sh").resolve()


# REGION AI: synchronous protective runner
def run_protective_process(
    filename: str,
    copies: int,
    profile: str = "",
    quality: str = "",
) -> bool:
    if copies < 1:
        raise ValueError("copies must be >= 1")
    if not _SCRIPT_PATH.exists():
        logger.error("❌ Script not found: %s", _SCRIPT_PATH)
        return False
    try:
        mode = _SCRIPT_PATH.stat().st_mode
        if not mode & 0o111:
            _SCRIPT_PATH.chmod(mode | 0o111)
    except OSError:
        logger.debug("Failed to ensure executable for %s", _SCRIPT_PATH, exc_info=True)
    cmd = ["./process_protective_v1.6.sh", filename, str(int(copies))]
    start_ts = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(BASE_DIR),
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
    if stdout:
        logger.info("process_protective stdout:\n%s", stdout.rstrip())
    if stderr:
        logger.warning("process_protective stderr:\n%s", stderr.rstrip())
    if proc.returncode == 0:
        logger.info("✅ Script completed successfully: %s (%.2fs)", filename, duration)
        return True
    logger.error(
        "❌ process_protective_v1.6.sh failed (code %s, %.2fs):\n%s",
        proc.returncode,
        duration,
        stderr or stdout,
    )
    return False
# END REGION AI
