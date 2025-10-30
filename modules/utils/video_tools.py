from __future__ import annotations

import argparse
import json
import logging
import math
import os
import random
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional

logger = logging.getLogger(__name__)

MODULE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = MODULE_DIR.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

try:
    from .meta_utils import TimestampBundle, filesystem_epoch_from, random_past_timestamp
except ImportError:  # pragma: no cover - fallback for script execution
    from modules.utils.meta_utils import TimestampBundle, filesystem_epoch_from, random_past_timestamp

try:
    from ..core.seed_utils import (
        current_rng,
        generate_seed,
        seeded_uniform,
    )
    from ..core.audit_manager import compute_trust_score
    from ..core.presets import get_profile
except ImportError:  # pragma: no cover - fallback for script execution
    from modules.core.seed_utils import current_rng, generate_seed, seeded_uniform
    from modules.core.audit_manager import compute_trust_score
    from modules.core.presets import get_profile


# REGION AI: executor helpers import
try:
    from ..executor import relaxed_bitrate_delta
except ImportError:  # pragma: no cover - fallback for script execution
    from modules.executor import relaxed_bitrate_delta
# END REGION AI

SOFTWARE_POOL = ["CapCut", "VN", "InShot", "iMovie"]
QT_DEVICE_POOL = [("Apple", "iPhone 14 Pro", "iPhone15,2"), ("Apple", "iPhone 13 mini", "iPhone14,4"), ("Samsung", "Galaxy S23 Ultra", "SM-S918B"), ("Samsung", "Galaxy S21", "SM-G991B")]
_SOFTWARE_BUILDERS = {"CapCut": lambda r: f"12.{r.randint(2, 6)}.{r.randint(0, 9)}", "VN": lambda r: f"2.{r.randint(10, 16)}.{r.randint(0, 9)}", "InShot": lambda r: f"1.{r.randint(70, 99)}.{r.randint(0, 9)}", "iMovie": lambda r: f"3.{r.randint(0, 3)}.{r.randint(0, 9)}"}
_VIDEO_MICRO_FILTERS = [
    ("soft_glow", "unsharp=lx=5:ly=5:la=0.25"),
    ("teal_orange", "colorbalance=bs=-0.015:rs=0.02"),
    ("film_curve", "curves=preset=vintage"),
    ("chromatic", "colorchannelmixer=rr=1.02:gg=1.00:bb=0.98"),
]
_BLUR_FILTERS = [
    ("gaussian_soft", "gblur=sigma=0.45"),
    ("avg_smooth", "avgblur=sizeX=3:sizeY=3"),
]


# REGION AI: audio filter helpers
_ANEQ_FAILURE_MARKERS = ("Option not found", "Invalid argument", "Result too large")
_ANEQ_RUNTIME_LOG = "[Audio] anequalizer failed validation, switching to equalizer (runtime recovery)"
_ANEQ_VALIDATED: Optional[bool] = None
_ANEQ_RUNTIME_OVERRIDE = False
_ANEQ_RUNTIME_LOGGED = False


def _audio_eq_safe_chain(freq: float, gain: float, *, runtime: bool = False) -> str:
    global _ANEQ_RUNTIME_LOGGED
    if runtime and not _ANEQ_RUNTIME_LOGGED:
        logging.warning(_ANEQ_RUNTIME_LOG)
        _ANEQ_RUNTIME_LOGGED = True
    return f"equalizer=f={freq}:t=q:w=1:g={gain}"


def build_audio_eq(freq: float = 1831.0, gain: float = -0.4, ffmpeg_log: Optional[str] = None) -> str:
    """Return a safe FFmpeg equalizer filter with runtime capability checks."""

    import subprocess

    global _ANEQ_VALIDATED, _ANEQ_RUNTIME_OVERRIDE

    if ffmpeg_log and any(marker in ffmpeg_log for marker in _ANEQ_FAILURE_MARKERS):
        _ANEQ_RUNTIME_OVERRIDE = True
        return _audio_eq_safe_chain(freq, gain, runtime=True)

    if _ANEQ_RUNTIME_OVERRIDE:
        return _audio_eq_safe_chain(freq, gain)

    if _ANEQ_VALIDATED is None:
        test_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-f",
            "lavfi",
            "-i",
            f"anequalizer=f={freq}:t=q:w=1:g={gain}",
            "-t",
            "0.1",
            "-f",
            "null",
            "-",
        ]
        try:
            probe = subprocess.run(
                test_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=3,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            _ANEQ_VALIDATED = False
        else:
            stderr = probe.stderr or ""
            if probe.returncode != 0 or any(marker in stderr for marker in _ANEQ_FAILURE_MARKERS):
                _ANEQ_VALIDATED = False
            else:
                _ANEQ_VALIDATED = True

    if not _ANEQ_VALIDATED:
        return _audio_eq_safe_chain(freq, gain)

    try:
        uniform = current_rng().uniform
    except RuntimeError:
        uniform = random.uniform
    bands = []
    for idx in range(1, 7):
        band_name = f"{idx}b"
        raw_val = uniform(-1.5, 21.5)
        if not math.isfinite(raw_val):
            logger.warning("Non-finite superequalizer value for %s", band_name)
            raw_val = 0.0
        clamped = max(0.0, min(raw_val, 20.0))
        if not math.isclose(raw_val, clamped, rel_tol=1e-9, abs_tol=1e-9):
            logger.warning(
                "Adjusted %s from %.3f to %.3f to satisfy FFmpeg superequalizer range",
                band_name,
                raw_val,
                clamped,
            )
        bands.append(f"{band_name}={clamped:.3f}")
    supereq = f"superequalizer={':'.join(bands)}"
    return f"{supereq},anequalizer=f={freq}:t=q:w=1:g={gain}"


# END REGION AI


@dataclass
class VariantConfig:
    seed: str
    fps: int
    bitrate_kbps: int
    maxrate_kbps: int
    bufsize_kbps: int
    scale_width: int
    scale_height: int
    pad_offset_x: int
    pad_offset_y: int
    crop_margin_w: int
    crop_margin_h: int
    crop_offset_x: int
    crop_offset_y: int
    brightness: float
    contrast: float
    saturation: float
    noise_strength: int
    codec: str
    video_profile: str
    video_level: str
    pix_fmt: str
    audio_codec: str
    audio_bitrate: str
    audio_rate: int
    profile_name: str
# REGION AI: encode quality controls
    crf: int = 20
    tune: str = "film"
# END REGION AI
    major_brand: str = "mp42"
    compatible_brands: str = "isommp42"
    max_duration: Optional[int] = None
    micro_filters: List[str] = field(default_factory=list)
    blur_filter: Optional[str] = None
    software: str = "iMovie 3.1.0"
    encoder: str = "Lavf62.3.82"
    timestamps: Optional[TimestampBundle] = None
    filesystem_epoch: Optional[float] = None
    audio_tempo: float = 1.0
    audio_pitch: float = 1.0
    audio_micro_filter: Optional[str] = None
    lut_descriptor: Optional[str] = None
    qt_make: Optional[str] = None
    qt_model: Optional[str] = None

    def to_dict(self) -> Dict[str, object]:
        payload: Dict[str, object] = {
            "seed": self.seed,
            "fps": self.fps,
            "bitrate_kbps": self.bitrate_kbps,
            "maxrate_kbps": self.maxrate_kbps,
            "bufsize_kbps": self.bufsize_kbps,
            "scale_width": self.scale_width,
            "scale_height": self.scale_height,
            "pad_offset_x": self.pad_offset_x,
            "pad_offset_y": self.pad_offset_y,
            "crop_margin_w": self.crop_margin_w,
            "crop_margin_h": self.crop_margin_h,
            "crop_offset_x": self.crop_offset_x,
            "crop_offset_y": self.crop_offset_y,
            "brightness": round(self.brightness, 4),
            "contrast": round(self.contrast, 4),
            "saturation": round(self.saturation, 4),
            "noise_strength": self.noise_strength,
            "codec": self.codec,
            "video_profile": self.video_profile,
            "video_level": self.video_level,
            "pix_fmt": self.pix_fmt,
            "audio_codec": self.audio_codec,
            "audio_bitrate": self.audio_bitrate,
            "audio_rate": self.audio_rate,
# REGION AI: encode quality serialization
            "crf": self.crf,
            "tune": self.tune,
# END REGION AI
            "major_brand": self.major_brand,
            "compatible_brands": self.compatible_brands,
            "profile_name": self.profile_name,
            "micro_filters": self.micro_filters,
            "blur_filter": self.blur_filter,
            "software": self.software,
            "encoder": self.encoder,
            "audio_tempo": round(self.audio_tempo, 4),
            "audio_pitch": round(self.audio_pitch, 4),
            "audio_micro_filter": self.audio_micro_filter,
            "lut_descriptor": self.lut_descriptor,
        }
        if self.timestamps is not None:
            payload["creation_time"] = self.timestamps.iso
            payload["creation_time_exif"] = self.timestamps.exif
        if self.filesystem_epoch is not None:
            payload["filesystem_epoch"] = self.filesystem_epoch
        if self.max_duration is not None:
            payload["max_duration"] = self.max_duration
        if self.qt_make:
            payload["qt_make"] = self.qt_make
        if self.qt_model:
            payload["qt_model"] = self.qt_model
        return payload


def _ensure_even(value: int) -> int:
    return value if value % 2 == 0 else value - 1


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _encoder_from_rng(rng: random.Random) -> str:
    minor = rng.randint(2, 6)
    patch = rng.randint(80, 140)
    return f"Lavf62.{minor}.{patch}"


def _pick_micro_variations(rng: random.Random) -> List[str]:
    filters: List[str] = []
    selected = rng.sample(_VIDEO_MICRO_FILTERS, k=rng.randint(1, 2))
    for _, filter_str in selected:
        filters.append(filter_str)
    if rng.random() < 0.45:
        _, blur_filter = rng.choice(_BLUR_FILTERS)
        filters.append(blur_filter)
    return filters


def _pick_lut_descriptor(filters: Iterable[str]) -> Optional[str]:
    if not filters:
        return None
    if any("colorbalance" in f or "colorchannelmixer" in f for f in filters):
        return "ColorMatrix"
    if any("curves" in f for f in filters):
        return "CurvesLUT"
    if any("gblur" in f or "avgblur" in f for f in filters):
        return "SoftBlur"
    return None


def _build_audio_micro_filter(
    sample_rate: int, tempo: float, pitch: float, seed: Optional[int] = None
) -> str:
    seeded = random.Random(seed) if seed is not None else None
    pick = (seeded.uniform if seeded else random.uniform)

    pitch_factor = _clamp(pitch, 0.94, 1.06)
    tempo_factor = _clamp(tempo, 0.94, 1.06)
    eq_filter = build_audio_eq(1831.0, -0.4)
    volume = pick(0.96, 1.02)
    echo_delay = int(round(pick(700, 1100)))
    echo_decay = pick(0.25, 0.35)
    chain = [
        "acompressor=threshold=-16dB:ratio=2.4",
        f"aresample={sample_rate:.0f}",
        eq_filter,
        f"volume={volume:.2f}",
        f"aecho=0.8:0.9:{echo_delay}:{echo_decay:.2f}",
        f"asetrate={sample_rate:.0f}*{pitch_factor:.4f}",
        f"aresample={sample_rate:.0f}",
        f"atempo={tempo_factor:.4f}",
    ]
    return ",".join(chain)


def generate_variant(
    input_name: str,
    copy_index: int,
    salt: str,
    profile_br_min: int,
    profile_br_max: int,
    base_width: int,
    base_height: int,
    audio_sample_rate: int,
    profile_name: str = "tiktok_hightrust",

) -> VariantConfig:
    seed = generate_seed(input_name, copy_index, salt)
    rng = current_rng()

    profile_settings = get_profile(profile_name)
    fps = rng.choice(profile_settings["fps"])
    video_codec = profile_settings["codec"]
    video_profile = profile_settings["profile"]
    video_level = str(profile_settings["level"])
    pix_fmt = profile_settings["pix_fmt"]
    audio_codec = profile_settings.get("audio_codec", "aac")
    audio_bitrate = profile_settings.get("audio_bitrate", "128k")
    audio_sample_rate = int(profile_settings.get("audio_rate", audio_sample_rate))
    major_brand = profile_settings.get("major_brand", "mp42")
    compatible_brands = profile_settings.get("compatible_brands", "isommp42")
    max_duration = profile_settings.get("max_duration")
    if profile_br_min <= 0 and profile_br_max <= 0:
        base_bitrate = 3600
    elif profile_br_max <= 0:
        base_bitrate = profile_br_min
    elif profile_br_min <= 0:
        base_bitrate = profile_br_max
    else:
        base_bitrate = (profile_br_min + profile_br_max) / 2
    bitrate = max(900, int(round(base_bitrate * seeded_uniform(0.9, 1.1))))
    maxrate = max(bitrate + 120, int(round(bitrate * seeded_uniform(1.08, 1.18))))
    bufsize = int(round(maxrate * seeded_uniform(1.8, 2.4)))

# REGION AI: vertical bitrate uplift and CRF policy
    if base_height > base_width:
        bitrate = int(round(seeded_uniform(6500, 9000)))
        maxrate = max(bitrate + 120, int(round(bitrate * seeded_uniform(1.05, 1.15))))
        bufsize = int(round(maxrate * seeded_uniform(1.9, 2.3)))
    clip_hint_raw = os.environ.get("UNICLON_TARGET_DURATION", "").strip()
    crf_value = 20
    if clip_hint_raw:
        try:
            if float(clip_hint_raw) < 20.0:
                crf_value = 18
        except ValueError:
            pass
    if crf_value != 18 and max_duration is not None and max_duration <= 20:
        crf_value = 18
# END REGION AI

    scale_w = _ensure_even(int(round(base_width * seeded_uniform(0.99, 1.01))))
    scale_h = _ensure_even(int(round(base_height * seeded_uniform(0.99, 1.01))))
    scale_w = max(2, scale_w)
    scale_h = max(2, scale_h)

    pad_offset_x = rng.randint(-max(2, int(base_width * 0.02)), max(2, int(base_width * 0.02)))
    pad_offset_y = rng.randint(-max(2, int(base_height * 0.02)), max(2, int(base_height * 0.02)))

    crop_margin_w = _ensure_even(rng.randint(4, 10))
    crop_margin_h = _ensure_even(rng.randint(4, 10))
    backoff_raw = os.environ.get("UNICLON_CROP_BACKOFF", "").strip()
    crop_backoff_depth = int(backoff_raw) if backoff_raw.isdigit() else 0
    if crop_backoff_depth:
        reduction_w = _ensure_even(min(crop_margin_w, crop_backoff_depth * 2))
        reduction_h = _ensure_even(min(crop_margin_h, crop_backoff_depth * 2))
        if reduction_w or reduction_h:
            logging.warning(
                "[CropGuard] Applying backoff depth %s (reduce margins by %sx%s)",
                crop_backoff_depth,
                reduction_w,
                reduction_h,
            )
            crop_margin_w = max(0, crop_margin_w - reduction_w)
            crop_margin_h = max(0, crop_margin_h - reduction_h)
    crop_offset_x = rng.randint(0, max(0, crop_margin_w))
    crop_offset_y = rng.randint(0, max(0, crop_margin_h))
    crop_w, crop_h = base_width - 2 * crop_margin_w, base_height - 2 * crop_margin_h
    crop_x, crop_y = crop_offset_x, crop_offset_y
    if crop_w <= 0 or crop_h <= 0:
        safe_w = min(base_width, max(64, base_width - 8))
        safe_h = min(base_height, max(64, base_height - 8))
        logging.warning("[CropGuard] Invalid crop size %sx%s, fallback to %sx%s", crop_w, crop_h, safe_w, safe_h)
        crop_w, crop_h, crop_x, crop_y = safe_w, safe_h, 0, 0
    if crop_x + crop_w > base_width or crop_y + crop_h > base_height:
        logging.warning("[CropGuard] Crop out of bounds, clamping to valid area")
        crop_x = max(0, base_width - crop_w)
        crop_y = max(0, base_height - crop_h)
    crop_w, crop_h = _ensure_even(int(crop_w)), _ensure_even(int(crop_h))
    if crop_w < 64 or crop_h < 64:
        logging.warning("[CropGuard] Crop too small, resetting to full frame")
        crop_w, crop_h, crop_x, crop_y = base_width, base_height, 0, 0
    crop_margin_w = max(0, _ensure_even(int((base_width - crop_w) / 2)))
    crop_margin_h = max(0, _ensure_even(int((base_height - crop_h) / 2)))
    crop_offset_x, crop_offset_y = max(0, min(int(crop_x), crop_margin_w)), max(0, min(int(crop_y), crop_margin_h))

    video_rng = random.Random(rng.getrandbits(31))
    brightness, contrast, saturation, gamma = (
        video_rng.uniform(-0.035, 0.035),
        1.0 + video_rng.uniform(-0.04, 0.04),
        1.0 + video_rng.uniform(-0.04, 0.04),
        1.0 + video_rng.uniform(-0.05, 0.05),
    )

    noise_roll = rng.random()
    noise_strength = 0
    if noise_roll > 0.35:
        noise_strength = rng.randint(1, 2)

    micro_filters = _pick_micro_variations(rng) + [f"eq=gamma={_clamp(gamma, 0.85, 1.15):.4f}"]
    lut_descriptor = _pick_lut_descriptor(micro_filters)

    software_base = rng.choice(SOFTWARE_POOL)
    software = f"{software_base} {_SOFTWARE_BUILDERS[software_base](rng)}"
    encoder = _encoder_from_rng(rng)

    qt_make, qt_model, _ = rng.choice(QT_DEVICE_POOL)

    timestamps = random_past_timestamp(rng, min_days=1, max_days=10)
    filesystem_epoch = filesystem_epoch_from(timestamps, rng)

    audio_rng = random.Random(rng.getrandbits(31)); audio_tempo = _clamp(audio_rng.uniform(0.96, 1.04), 0.94, 1.06); audio_pitch = _clamp(audio_rng.uniform(0.96, 1.04), 0.94, 1.06)
    audio_micro_filter = _build_audio_micro_filter(
        audio_sample_rate, audio_tempo, audio_pitch, seed=audio_rng.getrandbits(24)
    )

    return VariantConfig(
        seed=seed,
        fps=fps,
        bitrate_kbps=bitrate,
        maxrate_kbps=maxrate,
        bufsize_kbps=bufsize,
        scale_width=scale_w,
        scale_height=scale_h,
        pad_offset_x=pad_offset_x,
        pad_offset_y=pad_offset_y,
        crop_margin_w=crop_margin_w,
        crop_margin_h=crop_margin_h,
        crop_offset_x=crop_offset_x,
        crop_offset_y=crop_offset_y,
        brightness=brightness,
        contrast=contrast,
        saturation=saturation,
        noise_strength=noise_strength,
        micro_filters=micro_filters,
        blur_filter=None,
        software=software,
        encoder=encoder,
        timestamps=timestamps,
        filesystem_epoch=filesystem_epoch,
        audio_tempo=audio_tempo,
        audio_pitch=audio_pitch,
        audio_micro_filter=audio_micro_filter,
        lut_descriptor=lut_descriptor,
        qt_make=qt_make,
        qt_model=qt_model,
        codec=video_codec,
        video_profile=video_profile,
        video_level=video_level,
        pix_fmt=pix_fmt,
        audio_codec=audio_codec,
        audio_bitrate=audio_bitrate,
        audio_rate=audio_sample_rate,
        crf=crf_value,
        major_brand=major_brand,
        compatible_brands=compatible_brands,
        max_duration=max_duration,
        profile_name=profile_name,
    )


def _format_shell_assignments(data: Dict[str, object]) -> str:
    lines: List[str] = []
    for key, value in data.items():
        env_key = f"RAND_{key.upper()}"
        if isinstance(value, (list, tuple)):
            serialized = "|".join(str(item) for item in value if item)
            lines.append(f"{env_key}={shlex.quote(serialized)}")
        elif isinstance(value, float):
            lines.append(f"{env_key}={value:.6f}")
        else:
            lines.append(f"{env_key}={shlex.quote(str(value))}")
    return "\n".join(lines)


def _cli_generate(args: argparse.Namespace) -> int:
    variant = generate_variant(
        input_name=args.input,
        copy_index=args.copy_index,
        salt=args.salt,
        profile_br_min=args.profile_br_min,
        profile_br_max=args.profile_br_max,
        base_width=args.base_width,
        base_height=args.base_height,
        audio_sample_rate=args.audio_sample_rate,
        profile_name=args.profile_name,
    )
    data = variant.to_dict()
    if args.format == "json":
        json.dump(data, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif args.format == "shell":
        shell_payload = _format_shell_assignments(data)
        print(shell_payload)
    else:
        raise ValueError(f"Unsupported format: {args.format}")
    return 0


def _cli_score(args: argparse.Namespace) -> int:
    # REGION AI: bitrate tolerance for trust score
    bitrate_delta = relaxed_bitrate_delta(args.bitrate_delta)
    # END REGION AI
    score = compute_trust_score(
        args.ssim,
        args.phash,
        bitrate_delta,
        args.meta_diversity,
        args.time_diversity,
        profile_valid=args.profile_valid,
    )
    print(f"{score:.2f}")
    return 0


def _cli_touch(args: argparse.Namespace) -> int:
    epoch = float(args.epoch)
    atime = epoch + 3.0
    os.utime(args.file, (atime, epoch), follow_symlinks=False)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Uniclon Video Randomization Engine v1.7")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="Generate deterministic randomization payload")
    gen.add_argument("--input", required=True, help="Input filename (basename)")
    gen.add_argument("--copy-index", type=int, required=True)
    gen.add_argument("--salt", default="uniclon_v1.7")
    gen.add_argument("--profile-br-min", type=int, default=3200)
    gen.add_argument("--profile-br-max", type=int, default=5200)
    gen.add_argument("--base-width", type=int, default=1080)
    gen.add_argument("--base-height", type=int, default=1920)
    gen.add_argument("--audio-sample-rate", type=int, default=44100)
    gen.add_argument("--profile-name", default="tiktok_hightrust")
    gen.add_argument("--format", choices=["json", "shell"], default="json")
    gen.set_defaults(func=_cli_generate)

    score = sub.add_parser("score", help="Compute trust score from metrics")
    score.add_argument("--ssim", type=float, required=True)
    score.add_argument("--phash", type=float, required=True)
    score.add_argument("--bitrate-delta", type=float, default=0.0)
    score.add_argument("--meta-diversity", type=float, default=0.0)
    score.add_argument("--time-diversity", type=float, default=0.0)
    score.add_argument("--profile-valid", action="store_true")
    score.set_defaults(func=_cli_score)

    touch = sub.add_parser("touch", help="Apply filesystem timestamp with os.utime")
    touch.add_argument("--file", required=True)
    touch.add_argument("--epoch", required=True)
    touch.set_defaults(func=_cli_touch)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
