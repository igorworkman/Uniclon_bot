from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional

MODULE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = MODULE_DIR.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

try:
    from .meta_utils import TimestampBundle, filesystem_epoch_from, random_past_timestamp
except ImportError:  # pragma: no cover - fallback for script execution
    from modules.utils.meta_utils import TimestampBundle, filesystem_epoch_from, random_past_timestamp

SOFTWARE_POOL = [
    "CapCut 12.4.1",
    "VN 2.13.6",
    "iMovie 3.1.0",
    "Premiere Rush 2.5",
]
FPS_POOL = [24, 25, 30, 60]

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
    micro_filters: List[str] = field(default_factory=list)
    blur_filter: Optional[str] = None
    software: str = ""
    encoder: str = ""
    timestamps: Optional[TimestampBundle] = None
    filesystem_epoch: Optional[float] = None
    audio_tempo: float = 1.0
    audio_pitch: float = 1.0
    audio_micro_filter: Optional[str] = None
    lut_descriptor: Optional[str] = None

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
        return payload


def _ensure_even(value: int) -> int:
    return value if value % 2 == 0 else value - 1


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _derive_seed(input_name: str, copy_index: int, salt: str) -> str:
    stem = Path(input_name).name
    base = f"{stem}:{copy_index}:{salt}".encode("utf-8")
    return hashlib.md5(base).hexdigest()


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


def _build_audio_micro_filter(sample_rate: int, tempo: float, pitch: float) -> str:
    pitch_factor = _clamp(pitch, 0.94, 1.06)
    tempo_factor = _clamp(tempo, 0.94, 1.06)
    parts = [f"asetrate={sample_rate:.0f}*{pitch_factor:.4f}", f"aresample={sample_rate:.0f}"]
    parts.append(f"atempo={tempo_factor:.4f}")
    return ",".join(parts)


def generate_variant(
    input_name: str,
    copy_index: int,
    salt: str,
    profile_br_min: int,
    profile_br_max: int,
    base_width: int,
    base_height: int,
    audio_sample_rate: int,
) -> VariantConfig:
    seed = _derive_seed(input_name, copy_index, salt)
    seed_int = int(seed, 16)
    rng = random.Random(seed_int)

    fps = rng.choice(FPS_POOL)
    if profile_br_min <= 0 and profile_br_max <= 0:
        base_bitrate = 3600
    elif profile_br_max <= 0:
        base_bitrate = profile_br_min
    elif profile_br_min <= 0:
        base_bitrate = profile_br_max
    else:
        base_bitrate = (profile_br_min + profile_br_max) / 2
    bitrate = max(900, int(round(base_bitrate * rng.uniform(0.9, 1.1))))
    maxrate = max(bitrate + 120, int(round(bitrate * rng.uniform(1.08, 1.18))))
    bufsize = int(round(maxrate * rng.uniform(1.8, 2.4)))

    scale_w = _ensure_even(int(round(base_width * rng.uniform(0.99, 1.01))))
    scale_h = _ensure_even(int(round(base_height * rng.uniform(0.99, 1.01))))
    scale_w = max(2, scale_w)
    scale_h = max(2, scale_h)

    pad_offset_x = rng.randint(-max(2, int(base_width * 0.02)), max(2, int(base_width * 0.02)))
    pad_offset_y = rng.randint(-max(2, int(base_height * 0.02)), max(2, int(base_height * 0.02)))

    crop_margin_w = _ensure_even(rng.randint(4, 10))
    crop_margin_h = _ensure_even(rng.randint(4, 10))
    crop_offset_x = rng.randint(0, max(0, crop_margin_w))
    crop_offset_y = rng.randint(0, max(0, crop_margin_h))

    brightness = rng.uniform(-0.03, 0.03)
    contrast = 1.0 + rng.uniform(-0.03, 0.03)
    saturation = 1.0 + rng.uniform(-0.03, 0.03)

    noise_roll = rng.random()
    noise_strength = 0
    if noise_roll > 0.35:
        noise_strength = rng.randint(1, 2)

    micro_filters = _pick_micro_variations(rng)
    lut_descriptor = _pick_lut_descriptor(micro_filters)

    software = rng.choice(SOFTWARE_POOL)
    encoder = _encoder_from_rng(rng)

    timestamps = random_past_timestamp(rng, min_days=3, max_days=14)
    filesystem_epoch = filesystem_epoch_from(timestamps, rng)

    audio_tempo = rng.uniform(0.97, 1.03)
    audio_pitch = rng.uniform(0.97, 1.03)
    audio_micro_filter = _build_audio_micro_filter(audio_sample_rate, audio_tempo, audio_pitch)

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


def compute_trust_score(ssim: float, phash_delta: float) -> float:
    base = 4.2
    if phash_delta > 8:
        base += min(1.5, (phash_delta - 8) * 0.08)
    if ssim < 0.994:
        base += min(1.2, (0.994 - ssim) * 120)
    if ssim < 0.992 and phash_delta > 12:
        base += 0.6
    if ssim < 0.994 and phash_delta > 10:
        base = max(base, 5.1 + min(0.9, (phash_delta - 10) * 0.1))
    return round(_clamp(base, 3.5, 9.5), 2)


def _cli_score(args: argparse.Namespace) -> int:
    score = compute_trust_score(args.ssim, args.phash)
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
    gen.add_argument("--format", choices=["json", "shell"], default="json")
    gen.set_defaults(func=_cli_generate)

    score = sub.add_parser("score", help="Compute trust score from metrics")
    score.add_argument("--ssim", type=float, required=True)
    score.add_argument("--phash", type=float, required=True)
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
