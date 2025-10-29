from __future__ import annotations

import logging
import os
from typing import Callable, Iterable, List

logger = logging.getLogger(__name__)

def simplify_filter_chain(filter_chain: Iterable[str]) -> List[str]:
    """Drop heavy filters (noise/curves/lut) before a retry."""
    safe: List[str] = []
    for segment in filter_chain:
        lowered = segment.lower()
        if any(key in lowered for key in ("noise", "curves", "lut")):
            logger.debug("[Executor] Dropping filter for recovery: %s", segment)
            continue
        safe.append(segment)
    return safe or ["null"]


def ensure_output_integrity(
    output_file: str,
    filter_chain: Iterable[str],
    rerun_ffmpeg: Callable[[Iterable[str]], int],
) -> bool:
    """Validate FFmpeg output and trigger a recovery rerun when needed."""

    def _is_valid() -> bool:
        return os.path.exists(output_file) and os.path.getsize(output_file) >= 1024

    if _is_valid():
        return True

    if os.path.exists(output_file):
        size = os.path.getsize(output_file)
        logger.warning(
            "[Executor] Empty output (%d bytes) — retrying simplified render",
            size,
        )
        simplified_chain = simplify_filter_chain(filter_chain)
        if rerun_ffmpeg(simplified_chain) == 0 and _is_valid():
            logger.info("[Executor] ✅ Recovery success.")
            return True
        return False

    logger.error("[Executor] Missing output file — reattempting render")
    if rerun_ffmpeg(filter_chain) == 0 and _is_valid():
        logger.info("[Executor] ✅ Recovery success.")
        return True
    return False
