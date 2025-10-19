#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DIR="${BASE_DIR}/checks"
OUTPUT_DIR="${BASE_DIR}/Новая папка"
MANIFEST="${OUTPUT_DIR}/manifest.csv"
QUALITY="${CHECK_DIR}/quality_summary.csv"
META="${CHECK_DIR}/meta_summary.csv"
PHASH="${CHECK_DIR}/phash_summary.csv"
REPORT="${CHECK_DIR}/uniclon_report.csv"
mkdir -p "${CHECK_DIR}"

python3 - "$MANIFEST" "$QUALITY" "$META" "$PHASH" "$REPORT" "$OUTPUT_DIR" <<'PY'
import csv
import itertools
import math
import pathlib
import statistics
import subprocess
import sys
from typing import Dict, List, Optional

FRAME_SIZE = 32


def _load_map(path: pathlib.Path) -> Dict[str, Dict[str, str]]:
    data: Dict[str, Dict[str, str]] = {}
    if not path.exists():
        return data
    with path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            name = (row.get("file") or row.get("filename") or "").strip()
            if not name:
                continue
            data[name] = row
    return data


def _parse_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _select_bitrate(row: Dict[str, str]) -> Optional[float]:
    for key in ("bitrate_kbps", "bitrate"):
        candidate = row.get(key)
        parsed = _parse_float(candidate)
        if parsed is None:
            continue
        if key == "bitrate" and parsed > 100000:
            return parsed / 1000.0
        return parsed
    return None


def _read_frame(path: pathlib.Path) -> bytes:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(path),
        "-vf",
        f"scale={FRAME_SIZE}:{FRAME_SIZE}",
        "-vframes",
        "1",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "gray",
        "-",
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0 or len(proc.stdout) < FRAME_SIZE * FRAME_SIZE:
        raise RuntimeError(
            f"Failed to extract frame from {path} ({proc.stderr.decode(errors='replace').strip()})"
        )
    return proc.stdout[: FRAME_SIZE * FRAME_SIZE]


def _dct_1d(vector: List[float]) -> List[float]:
    n = len(vector)
    factor = math.pi / (2 * n)
    scale0 = math.sqrt(1 / n)
    scale = math.sqrt(2 / n)
    result: List[float] = []
    for k in range(n):
        acc = 0.0
        for idx, value in enumerate(vector):
            acc += value * math.cos((2 * idx + 1) * k * factor)
        result.append((scale0 if k == 0 else scale) * acc)
    return result


def _dct_2d(matrix: List[List[float]]) -> List[List[float]]:
    temp = [_dct_1d(row) for row in matrix]
    transposed = list(zip(*temp))
    return [list(vals) for vals in zip(*(_dct_1d(list(col)) for col in transposed))]


def _compute_phash_value(path: pathlib.Path) -> Optional[int]:
    try:
        frame = _read_frame(path)
    except Exception:
        return None
    matrix = [
        [frame[i * FRAME_SIZE + j] for j in range(FRAME_SIZE)]
        for i in range(FRAME_SIZE)
    ]
    dct_matrix = _dct_2d(matrix)
    top_left = [dct_matrix[i][j] for i in range(8) for j in range(8)]
    if len(top_left) <= 1:
        return None
    median = statistics.median(top_left[1:])
    bits = 0
    for value in top_left:
        bits = (bits << 1) | (1 if value > median else 0)
    return bits & ((1 << 64) - 1)


def _hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


manifest_path = pathlib.Path(sys.argv[1])
quality_path = pathlib.Path(sys.argv[2])
meta_path = pathlib.Path(sys.argv[3])
phash_path = pathlib.Path(sys.argv[4])
report_path = pathlib.Path(sys.argv[5])
output_dir = pathlib.Path(sys.argv[6])

report_path.parent.mkdir(parents=True, exist_ok=True)

manifest = _load_map(manifest_path)
quality = _load_map(quality_path)
meta = _load_map(meta_path)
phash_map = _load_map(phash_path)

all_names = sorted(set(manifest) | set(quality) | set(meta) | set(phash_map))

rows = []
phash_values: Dict[str, int] = {}

for name in all_names:
    m_row = manifest.get(name, {})
    q_row = quality.get(name, {})
    meta_row = meta.get(name, {})
    p_row = phash_map.get(name, {})

    ssim = _parse_float(q_row.get("SSIM") or q_row.get("ssim") or m_row.get("ssim"))
    psnr = _parse_float(q_row.get("PSNR") or q_row.get("psnr") or m_row.get("psnr"))
    phash_diff = _parse_float(
        p_row.get("pHash") or p_row.get("phash") or p_row.get("phash_diff")
    )
    bitrate = _select_bitrate(m_row)

    encoder = (meta_row.get("encoder") or m_row.get("encoder") or "").strip()
    software = (meta_row.get("software") or m_row.get("software") or "").strip()
    creation_time = (meta_row.get("creation_time") or m_row.get("creation_time") or "").strip()

    status = "OK"
    if ssim is None and psnr is None and phash_diff is None:
        status = "WARNING_NO_METRICS"
    elif ssim is not None and ssim < 0.94:
        status = "WARNING_LOW_SSIM"
    elif psnr is not None and psnr < 36:
        status = "WARNING_LOW_PSNR"
    elif phash_diff is not None and phash_diff < 12:
        status = "WARNING_LOW_PHASH"

    rows.append(
        {
            "file": name,
            "SSIM": f"{ssim:.3f}" if ssim is not None else "",
            "PSNR": f"{psnr:.2f}" if psnr is not None else "",
            "pHash": f"{phash_diff:.1f}" if phash_diff is not None else "",
            "bitrate_kbps": f"{bitrate:.1f}" if bitrate is not None else "",
            "encoder": encoder,
            "software": software,
            "creation_time": creation_time,
            "status": status,
        }
    )

    candidate_path = output_dir / name
    if candidate_path.exists():
        hash_value = _compute_phash_value(candidate_path)
        if hash_value is not None:
            phash_values[name] = hash_value


pair_diffs: List[int] = []
for (_, hash_a), (_, hash_b) in itertools.combinations(phash_values.items(), 2):
    pair_diffs.append(_hamming(hash_a, hash_b))

low_uniqueness = False
if pair_diffs:
    close_pairs = sum(1 for diff in pair_diffs if diff < 8)
    ratio = close_pairs / len(pair_diffs)
    if ratio > 0.6:
        low_uniqueness = True

if low_uniqueness:
    print(
        "⚠️ Warning: Copies are too similar (low uniqueness)\n"
        "Try regenerating with different seed or higher variation.",
        file=sys.stdout,
    )
    for row in rows:
        if "WARNING" in row["status"]:
            if "LOW_UNIQUENESS" not in row["status"]:
                row["status"] = f"{row['status']};LOW_UNIQUENESS"
        else:
            row["status"] = "WARNING_LOW_UNIQUENESS"


headers = [
    "file",
    "SSIM",
    "PSNR",
    "pHash",
    "bitrate_kbps",
    "encoder",
    "software",
    "creation_time",
    "status",
]

with report_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=headers)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
PY
