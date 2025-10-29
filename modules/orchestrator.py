"""Self-healing orchestrator helpers."""
from __future__ import annotations

import logging
import os
import time
from typing import Callable, Iterable, List

from .executor import simplify_filter_chain

_RECOVERY_CODES = {8, 22, 234}


def retry_render(
    run_ffmpeg: Callable[[Iterable[str]], int],
    filter_chain: Iterable[str],
) -> int:
    """Retry FFmpeg renders up to three times with filter simplification."""

    chain: List[str] = list(filter_chain)
    last_code = 0
    for attempt in range(3):
        result = run_ffmpeg(chain)
        if result == 0:
            logging.info("[Recovery] ✅ Successful retry on attempt %d", attempt + 1)
            os.environ.pop("UNICLON_CROP_BACKOFF", None)
            return 0
        last_code = result
        if result not in _RECOVERY_CODES:
            logging.error("[Recovery] ❌ Non-recoverable code=%s", result)
            return result
        logging.warning(
            "[Recovery] Attempt %d/3 failed (code=%s), simplifying filters…",
            attempt + 1,
            result,
        )
        backoff = attempt + 1
        os.environ["UNICLON_CROP_BACKOFF"] = str(backoff)
        logging.info("[Recovery] Applying UNICLON_CROP_BACKOFF=%s", backoff)
        chain = simplify_filter_chain(chain)
        time.sleep(1)
    logging.error("[Recovery] ❌ Failed after 3 attempts, skipping file")
    return last_code
