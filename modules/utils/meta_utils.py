from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass
from typing import Tuple

ISO_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"
EXIF_FORMAT = "%Y:%m:%d %H:%M:%S"


@dataclass(frozen=True)
class TimestampBundle:
    """Container for correlated timestamp representations."""

    utc: _dt.datetime
    iso: str
    exif: str
    epoch: float


def _ensure_timezone(dt: _dt.datetime) -> _dt.datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=_dt.timezone.utc)
    return dt.astimezone(_dt.timezone.utc)


def random_past_timestamp(
    rng,
    min_days: int = 3,
    max_days: int = 14,
    jitter_seconds: Tuple[int, int] = (-6 * 3600, 6 * 3600),
) -> TimestampBundle:
    """Return correlated timestamps shifted to the past.

    Args:
        rng: Deterministic random generator with ``randint``/``uniform`` API.
        min_days: Minimum number of days to go back from ``now``.
        max_days: Maximum number of days to go back from ``now``.
        jitter_seconds: Additional seconds jitter applied after subtracting days.
    """

    if min_days < 0:
        raise ValueError("min_days must be >= 0")
    if max_days < min_days:
        raise ValueError("max_days must be >= min_days")

    now = _dt.datetime.now(tz=_dt.timezone.utc)
    offset_days = rng.randint(min_days, max_days)
    offset_seconds = rng.randint(0, 24 * 3600 - 1)
    base = now - _dt.timedelta(days=offset_days, seconds=offset_seconds)

    jitter_low, jitter_high = jitter_seconds
    if jitter_low > jitter_high:
        jitter_low, jitter_high = jitter_high, jitter_low
    jitter = rng.randint(jitter_low, jitter_high)
    base = base + _dt.timedelta(seconds=jitter)
    base = _ensure_timezone(base)

    iso = base.strftime(ISO_FORMAT)
    # Trim microseconds for cleaner metadata while keeping deterministic output.
    if "." in iso:
        iso = iso[:-4] + "Z"
    exif = base.strftime(EXIF_FORMAT)
    epoch = base.timestamp()
    return TimestampBundle(utc=base, iso=iso, exif=exif, epoch=epoch)


def filesystem_epoch_from(bundle: TimestampBundle, rng) -> float:
    """Return a filesystem-friendly epoch derived from an existing bundle."""

    jitter = rng.uniform(-2.5 * 3600, 2.5 * 3600)
    return bundle.utc.timestamp() + jitter


__all__ = [
    "TimestampBundle",
    "random_past_timestamp",
    "filesystem_epoch_from",
]
