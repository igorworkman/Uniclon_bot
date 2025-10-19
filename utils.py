
import re
from pathlib import Path
from typing import Optional, Sequence, Tuple

# REGION AI: imports
from config import BASE_DIR
# END REGION AI


# REGION AI: dynamic imports
from importlib import import_module
# END REGION AI


def parse_copies_from_caption(caption: Optional[str]) -> Optional[int]:
    if not caption:
        return None
    m = re.search(r"(\d+)", caption)
    if not m:
        return None
    return int(m.group(1))


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
