from __future__ import annotations


def compute_trust_score(
    ssim: float,
    phash_delta: float,
    bitrate_delta: float,
    meta_diversity: float,
    time_diversity: float,
    profile_valid: bool = False,
) -> float:
    base = 3.5
    if phash_delta >= 8:
        base += (phash_delta - 8) * 0.08
    if ssim <= 0.994:
        base += (0.994 - ssim) * 120
    if bitrate_delta >= 10:
        base += 0.5
    if meta_diversity:
        base += 0.3
    if time_diversity:
        base += 0.3
    if profile_valid:
        base += 0.5
    return round(min(base, 9.9), 2)


def validate_profile(video_meta, target_profile):
    """Проверяет, совпадают ли параметры видео с профилем"""
    return (
        video_meta.get("codec") == target_profile["codec"]
        and video_meta.get("audio_rate") == target_profile["audio_rate"]
        and video_meta.get("major_brand") == target_profile["major_brand"]
    )


__all__ = ["compute_trust_score", "validate_profile"]
