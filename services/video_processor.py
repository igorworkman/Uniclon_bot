import asyncio
import logging
import os
import re
import subprocess
import time
from pathlib import Path
from typing import List, Optional

from config import BASE_DIR
from modules.executor import fix_final_crop_chain
from modules.utils.video_tools import build_audio_eq

logger = logging.getLogger(__name__)

# REGION AI: protective script paths
PROJECT_DIR = Path("/Users/teddy/Documents/Uniclon_bot")
OUTPUT_DIR = PROJECT_DIR / "output"
_SCRIPT_PATH = (PROJECT_DIR / "process_protective_v1.6.sh").resolve()
# END REGION AI

# The protective retry flow must serialize invocations so that diffs against the
# shared OUTPUT_DIR are not polluted by other concurrent runs.
_SEMAPHORE = asyncio.Semaphore(1)


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
            "outputs": [],
        }
    if not _SCRIPT_PATH.exists():
        logger.error("❌ Script not found: %s", _SCRIPT_PATH)
        return {
            "success_count": 0,
            "failed_count": copies,
            "temp_fail": False,
            "temp_error_count": 0,
            "log_tail": f"Script not found: {_SCRIPT_PATH}",
            "outputs": [],
        }

    
    def _invoke(requested: int) -> dict:
        initial_outputs = {p.resolve() for p in OUTPUT_DIR.glob("*.mp4")}
        try:
            mode = _SCRIPT_PATH.stat().st_mode
            if not mode & 0o111:
                _SCRIPT_PATH.chmod(mode | 0o111)
        except OSError:
            logger.debug("Failed to ensure executable for %s", _SCRIPT_PATH, exc_info=True)
        cmd = ["./process_protective_v1.6.sh", str(full_path), str(int(requested))]
        start_ts = time.monotonic()

        def _needs_audio_recovery(return_code: int, log_blob: str) -> bool:
            if return_code not in {8, 234}:
                return False
            return any(marker in log_blob for marker in ("Option not found", "Result too large"))

        def _run_process(env: Optional[dict] = None) -> subprocess.CompletedProcess[str]:
            actual_cmd = cmd
            if isinstance(cmd, str) and "ffmpeg" in cmd:
                match = re.search(r"-(?:vf|filter_complex)\s+(['\"])(.+?)\1", cmd)
                if match:
                    filter_chain = fix_final_crop_chain(match.group(2))
                    logger.info(f"[CropSanity] Final chain verified: {filter_chain}")
                    actual_cmd = f"{cmd[:match.start(2)]}{filter_chain}{cmd[match.end(2):]}"
            elif isinstance(cmd, (list, tuple)) and cmd and cmd[0] == "ffmpeg":
                actual_cmd = list(cmd)
                for flag in ("-vf", "-filter_complex"):
                    if flag in actual_cmd:
                        idx = actual_cmd.index(flag)
                        if idx + 1 < len(actual_cmd):
                            filter_chain = fix_final_crop_chain(actual_cmd[idx + 1])
                            logger.info(f"[CropSanity] Final chain verified: {filter_chain}")
                            actual_cmd[idx + 1] = filter_chain
            return subprocess.run(
                actual_cmd,
                cwd=str(PROJECT_DIR),
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )

        attempt_outputs = []
        recovery_env = None
        audio_recovery_applied = False
        crop_backoff_depth = 0
        proc: subprocess.CompletedProcess[str]
        try:
            for attempt in range(1, 6):
                try:
                    proc = _run_process(recovery_env)
                except FileNotFoundError:
                    logger.error("❌ Unable to execute %s", _SCRIPT_PATH, exc_info=True)
                    return {
                        "success_count": 0,
                        "failed_count": requested,
                        "temp_fail": False,
                        "temp_error_count": 0,
                        "log_tail": f"Unable to execute {_SCRIPT_PATH}",
                        "fatal": True,
                        "outputs": [],
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
                        "outputs": [],
                    }

                stdout = proc.stdout or ""
                stderr = proc.stderr or ""
                attempt_outputs.append((stdout, stderr))
                combined_log = "\n".join(
                    part
                    for out_stdout, out_stderr in attempt_outputs
                    for part in (out_stdout, out_stderr)
                    if part
                )
                if not audio_recovery_applied and _needs_audio_recovery(proc.returncode, combined_log):
                    override_chain = build_audio_eq(ffmpeg_log=combined_log)
                    if override_chain.startswith("equalizer="):
                        if recovery_env is None:
                            recovery_env = os.environ.copy()
                        recovery_env["UNICLON_AUDIO_EQ_OVERRIDE"] = override_chain
                        audio_recovery_applied = True
                        continue

                if proc.returncode == -22 and crop_backoff_depth < 3:
                    crop_backoff_depth += 1
                    if recovery_env is None:
                        recovery_env = os.environ.copy()
                    recovery_env["UNICLON_CROP_BACKOFF"] = str(crop_backoff_depth)
                    logger.warning("[CropGuard] FFmpeg error -22 detected, retrying with crop backoff=%s", crop_backoff_depth)
                    continue

                break
        finally:
            duration = time.monotonic() - start_ts

        stdout, stderr = attempt_outputs[-1] if attempt_outputs else ("", "")
        combined = "\n".join(
            part
            for out_stdout, out_stderr in attempt_outputs
            for part in (out_stdout, out_stderr)
            if part
        )
        after_outputs = {p.resolve() for p in OUTPUT_DIR.glob("*.mp4")}
        new_outputs: List[str] = [
            str(path)
            for path in sorted(after_outputs - initial_outputs)
        ]
        lines = combined.splitlines()
        tail20 = "\n".join(lines[-20:]) if lines else combined
        success_count = len(re.findall(r"Generated copy #\\d+", combined))
        failed_count = len(re.findall(r"Failed copy #\\d+", combined))
        temp_fail = False
        fatal = False
        rc = proc.returncode
        markers = (
            "[WARN] Uniqueness low but accepted",
            "[Fallback] Copy",
            "[Retry] Similarity low",
        )
        if rc != 0:
            tail10 = "\n".join(lines[-10:]) if lines else combined
            temp_fail = any(marker in tail10 for marker in markers)
            if temp_fail:
                logger.warning("⚠️ Зафиксирована временная ошибка (rc=%s).", rc)
            else:
                fatal = True
                logger.error(
                    "⚠️ Скрипт завершился с кодом %s: %s",
                    rc,
                    (stderr or stdout).strip() or "no output",
                )
        else:
            if stdout:
                logger.info("process_protective stdout:\n%s", stdout.rstrip())
            if stderr:
                logger.warning("process_protective stderr:\n%s", stderr.rstrip())
            logger.info("✅ Скрипт успешно завершён: %s (%.2fs)", full_path, duration)
            logger.info("📂 Готовые файлы доступны в %s", OUTPUT_DIR)
            logger.info("[CleanMeta] udta and directory metadata wiped")
            if any(marker in combined for marker in markers):
                temp_fail = True
                logger.warning(
                    "⚠️ Зафиксирована временная ошибка: обнаружены предупреждения об уникальности."
                )
        if not tail20.strip():
            tail20 = (stderr or stdout).strip() or f"Process exited with code {rc}"
        remaining_failed = max(0, requested - success_count)
        return {
            "success_count": success_count,
            "failed_count": failed_count or remaining_failed,
            "temp_fail": temp_fail,
            "temp_error_count": remaining_failed if temp_fail else 0,
            "log_tail": tail20,
            "fatal": fatal,
            "outputs": new_outputs,
        }

    total_success = 0
    total_temp_errors = 0
    fatal_error = False
    log_tail_parts = []
    collected_outputs: List[str] = []
    while total_success < copies and not fatal_error:
        requested = copies - total_success
        result = _invoke(requested)
        total_success += result["success_count"]
        total_temp_errors += result.get("temp_error_count", 0)
        fatal_error = result.get("fatal", False)
        log_tail_parts.append(result.get("log_tail", ""))
        collected_outputs.extend(result.get("outputs", []))
        if not result.get("temp_fail"):
            break
        if result["success_count"] == 0:
            break

    failed_total = max(0, copies - total_success)
    final_tail = "\n---\n".join([tail for tail in log_tail_parts if tail])

    return {
        "success_count": total_success,
        "failed_count": failed_total,
        "temp_fail": total_temp_errors > 0,
        "temp_error_count": total_temp_errors,
        "log_tail": final_tail,
        "outputs": collected_outputs,
    }
# END REGION AI


async def run_protective_process_async(
    filename: str,
    copies: int,
    profile: str = "",
    quality: str = "",
) -> dict:
    async with _SEMAPHORE:
        return await asyncio.to_thread(
            run_protective_process,
            filename,
            copies,
            profile,
            quality,
        )
