from __future__ import annotations

import logging, os, re, random
from typing import Callable, Dict, Iterable, List

# REGION AI: metadata imports
from .metadata import generate_meta_variants
# END REGION AI

logger = logging.getLogger(__name__)


def reconcile_crop_scale(filter_chain: str) -> str:
    """
    Гарантирует, что значения crop <= scale.
    Исправляет ошибки 'Invalid too big or non positive size' (-22, 234)
    """

    # Найти scale
    scale_match = re.search(r"scale=(\d+):(\d+)", filter_chain)
    if not scale_match:
        return filter_chain

    scale_w, scale_h = map(int, scale_match.groups())

    # Найти crop
    crop_match = re.search(r"crop=(\d+):(\d+):(\d+):(\d+)", filter_chain)
    if not crop_match:
        return filter_chain

    crop_w, crop_h, x, y = map(int, crop_match.groups())

    # Исправить значения, если превышают scale
    if crop_w > scale_w or crop_h > scale_h or crop_w <= 0 or crop_h <= 0:
        new_w = min(crop_w, scale_w)
        new_h = min(crop_h, scale_h)
        logging.warning(
            f"[CropReconcile] corrected crop {crop_w}x{crop_h} → {new_w}x{new_h}"
        )
        filter_chain = re.sub(
            r"crop=\d+:\d+:\d+:\d+",
            f"crop={new_w}:{new_h}:{x}:{y}",
            filter_chain,
        )

    return filter_chain

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


def fix_final_crop_chain(filter_chain: str) -> str:
    """Проверяет и правит некорректные параметры crop после генерации всей цепочки фильтров."""

    pattern = r"crop=(\d+):(\d+):(\d+):(\d+)"

    def _clamp(match: re.Match[str]) -> str:
        w, h, x, y = map(int, match.groups())
        if w <= 0 or h <= 0:
            logging.warning(
                f"[CropFinal] Invalid size {w}x{h}, corrected to 1080x1920"
            )
            w, h = 1080, 1920
        if w > 1080:
            logging.warning(f"[CropFinal] Width too large ({w}), clamped to 1080")
            w = 1080
        if h > 1920:
            logging.warning(f"[CropFinal] Height too large ({h}), clamped to 1920")
            h = 1920
        return f"crop={w}:{h}:{x}:{y}"

    return re.sub(pattern, _clamp, filter_chain)


def sanitize_audio_filter(filter_chain: str) -> str:
    replacements = {
        "anequalizer": "aecho=0.8:0.9:1000:0.3",
        "apulsator": "aecho=0.8:0.9:1000:0.3",
        "afir": "atempo=1.0",
        "afreqshift": "atempo=1.0",
    }
    for bad, safe in replacements.items():
        if bad in filter_chain:
            logging.warning(
                f"[AudioGuard] '{bad}' not supported — replaced with '{safe}'"
            )
            filter_chain = filter_chain.replace(bad, safe)
    return filter_chain


def sanitize_filter_chain(filter_chain: Iterable[str]) -> List[str]:
    sanitized = [
        reconcile_crop_scale(
            fix_final_crop_chain(
                sanitize_audio_filter(sanitize_crop_filter(segment))
            )
        )
        for segment in filter_chain
    ]
    if sanitized:
        logging.info(
            "[CropPreCheck] Validated crop parameters → %s",
            ", ".join(sanitized),
        )
        logger.info("[AudioGuard] Final audio filter chain → %s", ", ".join(sanitized))
    else:
        logging.info("[CropPreCheck] Validated crop parameters → <empty>")
    return sanitized


# REGION AI: meta shift variants
def apply_copy_metashift(profile: Dict[str, object], base_fps: float, base_bitrate: float, base_pitch: float = 1.0) -> Dict[str, object]:
    variant = generate_meta_variants(profile or {})
    fps = max(1, int(round(float(base_fps or 0) + random.randint(-2, 2))))
    bitrate_seed = float(base_bitrate or (profile or {}).get("bitrate") or 1200); bitrate = max(128, int(round(bitrate_seed * (1.0 + random.uniform(-0.1, 0.1)))))
    swing = random.uniform(0.005, 0.01) * (1 if random.random() >= 0.5 else -1); pitch = round(base_pitch * (1.0 + swing), 6)
    logging.info("[MetaShift] fps=%s | bitrate=%s | pitch=%.4f | encoder=%s | software=%s | creation=%s", fps, bitrate, pitch, variant["encoder"], variant["software"], variant["creation_time"]); variant.update({"fps": fps, "bitrate": bitrate, "audio_pitch": pitch})
    return variant


# END REGION AI
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
