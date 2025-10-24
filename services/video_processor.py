import logging
import subprocess
import time
from config import BASE_DIR

logger = logging.getLogger(__name__)
_SCRIPT_PATH = (BASE_DIR / "process_protective_v1.6.sh").resolve()


def run_protective_process(filename: str, copies: int) -> bool:
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
    for attempt in range(2):
        try:
            proc = subprocess.run(cmd, cwd=str(BASE_DIR), capture_output=True, text=True, check=False)
        except FileNotFoundError:
            logger.error("❌ Unable to execute %s", _SCRIPT_PATH, exc_info=True)
            return False
        except OSError as exc:
            logger.error("❌ Failed to spawn process_protective_v1.6.sh: %s", exc)
            return False
        stdout, stderr = proc.stdout or "", proc.stderr or ""
        if stdout:
            logger.info("process_protective stdout (attempt %d):\n%s", attempt + 1, stdout.rstrip())
        if stderr:
            logger.warning("process_protective stderr (attempt %d):\n%s", attempt + 1, stderr.rstrip())
        if proc.returncode == 0:
            logger.info("✅ Script completed successfully: %s", filename)
            return True
        if "RETRY" in stdout or "UniqScore=0.0" in stdout:
            logger.warning("⚠️ Retry triggered for %s (attempt %d)", filename, attempt + 1)
            time.sleep(1)
            continue
        logger.error("❌ process_protective_v1.6.sh failed (code %s):\n%s", proc.returncode, stderr or stdout)
        return False
    return False
