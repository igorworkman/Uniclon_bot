import asyncio
import logging
import os
from pathlib import Path
from typing import List, Tuple

# REGION AI: imports
from config import SCRIPT_PATH, OUTPUT_DIR
# END REGION AI


logger = logging.getLogger(__name__)


async def run_script_with_logs(
    input_file: Path, copies: int, cwd: Path, profile: str
) -> Tuple[int, str]:
    """Запускает bash-скрипт и возвращает (returncode, объединённые логи)."""
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Script not found: {SCRIPT_PATH}")

    # ensure +x
    try:
        SCRIPT_PATH.chmod(SCRIPT_PATH.stat().st_mode | 0o111)
    except Exception:
        pass

    normalized_profile = (profile or "").strip().lower()
    if normalized_profile == "default":
        normalized_profile = ""

    valid_profiles = {"tiktok", "instagram", "telegram"}
    profile_args: List[str] = []
    if normalized_profile in valid_profiles:
        profile_args = ["--profile", normalized_profile]
    elif normalized_profile:
        logger.warning(
            "Unknown profile '%s' for %s; invoking script without --profile",
            normalized_profile,
            input_file.name,
        )
        normalized_profile = ""

    proc = await asyncio.create_subprocess_exec(
        str(SCRIPT_PATH),
        input_file.name,
        str(int(copies)),
        *profile_args,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=os.environ.copy(),
    )

    lines: List[str] = []
    assert proc.stdout is not None
    async for raw in proc.stdout:
        decoded = raw.decode(errors="replace")
        lines.append(decoded)
        message = decoded.rstrip("\n")
        if message:
            logger.info(
                "[%s|copies=%s|profile=%s] %s",
                input_file.name,
                copies,
                normalized_profile or "-",
                message,
            )
        else:
            logger.info(
                "[%s|copies=%s|profile=%s]",
                input_file.name,
                copies,
                normalized_profile or "-",
            )

    rc = await proc.wait()
    if rc != 0:
        tail = "".join(lines[-10:])
        logger.error(
            "Script %s exited with code %s for %s (copies=%s). Tail logs:\n%s",
            SCRIPT_PATH,
            rc,
            input_file.name,
            copies,
            tail,
        )
        raise RuntimeError(
            f"Script {SCRIPT_PATH.name} exited with code {rc}. Tail logs:\n{tail}"
        )

    return rc, "".join(lines)


async def list_new_mp4s(since_ts: float, name_hint: str = "") -> List[Path]:
    files: List[Path] = []
    for p in OUTPUT_DIR.glob("*.mp4"):
        try:
            if p.stat().st_mtime >= since_ts - 0.5:
                files.append(p)
        except FileNotFoundError:
            continue
    files.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return files
