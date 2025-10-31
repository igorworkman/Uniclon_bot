
import logging
import random
import re
import shutil
import time
from pathlib import Path
from typing import Optional, Sequence, Tuple

# REGION AI: imports
from config import BASE_DIR, CHECKS_DIR, OUTPUT_DIR
# END REGION AI


# REGION AI: dynamic imports
from importlib import import_module
# END REGION AI


logger = logging.getLogger(__name__)



def auto_cleanup_temp_dirs(threshold_hours: int = 6) -> int:
    """Удаляет временные файлы и каталоги старше указанного порога (по умолчанию 6 часов)."""
    now = time.time()
    cleaned = 0
    targets = [BASE_DIR / "temp", OUTPUT_DIR / "tmp", CHECKS_DIR / "tmp"]
    for folder in targets:
        if not folder.exists():
            continue
        for item in folder.iterdir():
            try:
                age_hours = (now - item.stat().st_mtime) / 3600
                if age_hours > threshold_hours:
                    if item.is_dir():
                        shutil.rmtree(item)
                    else:
                        item.unlink()
                    cleaned += 1
            except Exception as e:  # noqa: BLE001
                logger.warning(f"[Cleanup] Failed to remove {item}: {e}")
    if cleaned > 0:
        logger.info(f"[Cleanup] Auto-removed {cleaned} old temp files (>{threshold_hours}h)")
    return cleaned




def parse_copies_from_caption(caption: Optional[str]) -> Optional[int]:
    if not caption:
        return None
    match = re.search(r"copies\s*=\s*(\d+)", caption, re.IGNORECASE)
    if not match:
        match = re.search(r"(\d+)", caption)
    return int(match.group(1)) if match else None


def parse_filename_and_copies(text: Optional[str]) -> Optional[Tuple[Path, int]]:
    """Парсит строку вида: "file name.mp4 10" -> (Path, copies)."""
    if not text:
        return None
    m = re.search(r"(?i)\b([\w\-. ]+\.mp4)\b\s+(\d+)\b", text)
    if not m:
        return None
    filename = m.group(1).strip()
    copies = int(m.group(2))
    return (BASE_DIR / filename, copies)


# REGION AI: bot helpers
async def perform_self_audit(source: Path, generated_files: Sequence[Path]):
    if random.random() < 0.15:
        cleaned = auto_cleanup_temp_dirs()
        logger.info(f"[Cleanup] Periodic cleanup triggered ({cleaned} items)")
    module = import_module("uniclon_bot")
    impl = getattr(module, "_perform_self_audit_impl")
    return await impl(source, generated_files)


def cleanup_user_outputs(
    user_id: int,
    *,
    keep_newer_than: Optional[float] = None,
    max_mtime: Optional[float] = None,
):
    module = import_module("handlers")
    impl = getattr(module, "_cleanup_user_outputs_impl")
    return impl(
        user_id,
        keep_newer_than=keep_newer_than,
        max_mtime=max_mtime,
    )
# END REGION AI


def auto_cleanup_temp_dirs(threshold_hours: int = 6) -> int:
    now = time.time()
    cleaned = 0
    for folder in [BASE_DIR / "temp", OUTPUT_DIR / "tmp", CHECKS_DIR / "tmp"]:
        if not folder.exists():
            continue
        for item in folder.iterdir():
            try:
                age = now - item.stat().st_mtime
            except OSError:
                continue
            if age <= threshold_hours * 3600:
                continue
            if item.is_file():
                try:
                    item.unlink()
                    cleaned += 1
                except Exception:
                    pass
            elif item.is_dir():
                try:
                    shutil.rmtree(item)
                    cleaned += 1
                except Exception:
                    pass
    return cleaned


if random.random() < 0.15:
    try:
        cleaned = auto_cleanup_temp_dirs()
    except Exception:
        logger.debug("Auto-cleanup temp dirs failed", exc_info=True)
    else:
        logger.info("[Cleanup] Auto-removed %s old temp files", cleaned)
