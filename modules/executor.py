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


def sanitize_crop_filter(filter_chain: str) -> str:
    import re

    pattern = r"crop=(-?\d+):(-?\d+):(-?\d+):(-?\d+)"
    match = re.search(pattern, filter_chain)
    if not match:
        return filter_chain
    w, h, x, y = map(int, match.groups())
    if w <= 0 or h <= 0:
        logging.warning(
            f"[CropPreCheck] Invalid crop size ({w}x{h}) → fallback 64x64"
        )
        w, h = 64, 64
    if w < 64 or h < 64:
        logging.warning(
            f"[CropPreCheck] Too small crop ({w}x{h}) → padded to 64x64"
        )
        w, h = 64, 64
    if w > 1080 or h > 1920:
        logging.warning(
            f"[CropPreCheck] Too large crop ({w}x{h}) → clamped to 1080x1920"
        )
        w, h = 1080, 1920
    safe_chain = re.sub(pattern, f"crop={w}:{h}:{x}:{y}", filter_chain)
    return safe_chain


def sanitize_filter_chain(filter_chain: Iterable[str]) -> List[str]:
    sanitized = [sanitize_crop_filter(segment) for segment in filter_chain]
    if sanitized:
        logging.info(
            "[CropPreCheck] Validated crop parameters → %s",
            ", ".join(sanitized),
        )
    else:
        logging.info("[CropPreCheck] Validated crop parameters → <empty>")
    return sanitized


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
        sanitized_chain = sanitize_filter_chain(filter_chain)
        simplified_chain = simplify_filter_chain(sanitized_chain)
        if rerun_ffmpeg(simplified_chain) == 0 and _is_valid():
            logger.info("[Executor] ✅ Recovery success.")
            return True
        return False

    logger.error("[Executor] Missing output file — reattempting render")
    sanitized_chain = sanitize_filter_chain(filter_chain)
    if rerun_ffmpeg(sanitized_chain) == 0 and _is_valid():
        logger.info("[Executor] ✅ Recovery success.")
        return True
    return False
