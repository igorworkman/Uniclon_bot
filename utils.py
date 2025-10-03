
import re
from pathlib import Path
from typing import Optional, Tuple

# REGION AI: imports
from config import BASE_DIR
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
