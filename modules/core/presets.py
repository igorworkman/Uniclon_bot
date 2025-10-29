"""Video encoding presets for platform-specific profiles."""
from __future__ import annotations

from typing import Any, Dict

VIDEO_PROFILES: Dict[str, Dict[str, Any]] = {
    "tiktok_hightrust": {
        "codec": "libx264",
        "profile": "high",
        "level": "4.0",
        "pix_fmt": "yuv420p",
        "fps": [30, 60],
        "audio_codec": "aac",
        "audio_rate": 44100,
        "audio_bitrate": "128k",
        "major_brand": "mp42",
        "compatible_brands": "isommp42",
        "max_duration": 60,
    },
    "instagram_reel": {
        "codec": "libx264",
        "profile": "high",
        "level": "4.1",
        "fps": [30],
        "audio_rate": 48000,
        "major_brand": "isom",
    },
    "youtube_short": {
        "codec": "libx264",
        "profile": "high",
        "level": "4.2",
        "fps": [30, 60],
        "audio_rate": 48000,
        "major_brand": "mp42",
    },
}


def get_profile(name: str) -> Dict[str, Any]:
    """Return encoding profile settings by name with safe fallbacks."""
    fallback = VIDEO_PROFILES["tiktok_hightrust"]
    profile = VIDEO_PROFILES.get(name)
    if profile is None:
        return fallback.copy()
    merged = fallback.copy()
    merged.update(profile)
    return merged


__all__ = ["VIDEO_PROFILES", "get_profile"]
