
import re
from pathlib import Path
from typing import Optional, Tuple
from uniclon.config import MAX_COPIES, BASE_DIR


def parse_copies_from_caption(caption: Optional[str]) -> Optional[int]:
    if not caption:
        return None
    m = re.search(r"(\d+)", caption)
    if not m:
        return None
    n = int(m.group(1))
    return max(1, min(MAX_COPIES, n))


def parse_filename_and_copies(text: Optional[str]) -> Optional[Tuple[Path, int]]:
    """Парсит строку вида: "file name.mp4 10" -> (Path, copies)."""
    if not text:
        return None
    m = re.search(r"(?i)\b([\w\-. ]+\.mp4)\b\s+(\d+)\b", text)
    if not m:
        return None
    filename = m.group(1).strip()
    copies = max(1, min(MAX_COPIES, int(m.group(2))))
    return (BASE_DIR / filename, copies)
