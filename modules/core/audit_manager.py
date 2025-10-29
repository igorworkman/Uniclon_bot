from __future__ import annotations

from typing import Final


_MAX_SCORE: Final[float] = 10.0
_MIN_SCORE: Final[float] = 0.0


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def compute_trust_score(
    ssim: float,
    phash_delta: float,
    bitrate_delta: float,
    meta_diversity: float,
    time_diversity: float,
) -> float:
    base = 5.0
    base += _clamp(phash_delta * 0.18, 0.0, 2.0)
    base += _clamp((1.0 - _clamp(ssim, 0.0, 1.0)) * 160.0, 0.0, 2.1)
    base += _clamp(abs(bitrate_delta) * 0.12, 0.0, 1.6)
    base += _clamp(meta_diversity * 1.5, 0.0, 1.5)
    base += _clamp(time_diversity * 1.2, 0.0, 1.2)
    return round(_clamp(base, _MIN_SCORE, _MAX_SCORE), 2)


__all__ = ["compute_trust_score"]
