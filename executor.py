import asyncio
import os
from pathlib import Path
from typing import List, Tuple

from uniclon.config import SCRIPT_PATH, OUTPUT_DIR


async def run_script_with_logs(input_file: Path, copies: int, cwd: Path) -> Tuple[int, str]:
    """Запускает bash-скрипт и возвращает (returncode, объединённые логи)."""
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Script not found: {SCRIPT_PATH}")

    # ensure +x
    try:
        SCRIPT_PATH.chmod(SCRIPT_PATH.stat().st_mode | 0o111)
    except Exception:
        pass

    proc = await asyncio.create_subprocess_exec(
        str(SCRIPT_PATH), input_file.name, str(int(copies)),
        cwd=str(cwd), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        env=os.environ.copy(),
    )

    lines: List[str] = []
    assert proc.stdout is not None
    async for raw in proc.stdout:
        lines.append(raw.decode(errors="replace"))

    rc = await proc.wait()
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
