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

python3 - "$MANIFEST" "$QUALITY" "$META" "$PHASH" "$REPORT" <<'PY'
import csv
import pathlib
import sys
from typing import Dict

manifest_path = pathlib.Path(sys.argv[1])
quality_path = pathlib.Path(sys.argv[2])
meta_path = pathlib.Path(sys.argv[3])
phash_path = pathlib.Path(sys.argv[4])
report_path = pathlib.Path(sys.argv[5])
report_path.parent.mkdir(parents=True, exist_ok=True)


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


manifest = _load_map(manifest_path)
quality = _load_map(quality_path)
meta = _load_map(meta_path)
phash = _load_map(phash_path)

all_names = set(manifest) | set(quality) | set(meta) | set(phash)

headers = [
    "file",
    "ssim",
    "psnr",
    "phash_diff",
    "bitrate_kbps",
    "encoder",
    "software",
    "creation_time",
    "status",
]

with report_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.writer(fh)
    writer.writerow(headers)

    for name in sorted(all_names):
        m_row = manifest.get(name, {})
        q_row = quality.get(name, {})
        meta_row = meta.get(name, {})
        p_row = phash.get(name, {})

        def _parse_float(value):
            try:
                return float(value)
            except (TypeError, ValueError):
                return None

        bitrate_raw = _parse_float(m_row.get("bitrate"))
        if bitrate_raw is None:
            bitrate_raw = _parse_float(m_row.get("bitrate_kbps"))
        bitrate_kbps = None
        if bitrate_raw is not None:
            bitrate_kbps = bitrate_raw / 1000 if bitrate_raw > 100 else bitrate_raw

        ssim = _parse_float(q_row.get("SSIM") or q_row.get("ssim") or m_row.get("ssim"))
        psnr = _parse_float(q_row.get("PSNR") or q_row.get("psnr") or m_row.get("psnr"))
        phash_diff = _parse_float(p_row.get("phash_diff") or p_row.get("phash"))

        encoder = (meta_row.get("encoder") or m_row.get("encoder") or "").strip()
        software = (meta_row.get("software") or m_row.get("software") or "").strip()
        creation_time = (meta_row.get("creation_time") or m_row.get("creation_time") or "").strip()

        status = "OK"
        if ssim is not None and ssim < 0.94:
            status = "LOW_SSIM"
        elif psnr is not None and psnr < 36:
            status = "LOW_PSNR"
        elif phash_diff is not None and phash_diff < 12:
            status = "LOW_DIFF"

        writer.writerow([
            name,
            f"{ssim:.3f}" if ssim is not None else "",
            f"{psnr:.2f}" if psnr is not None else "",
            f"{phash_diff:.1f}" if phash_diff is not None else "",
            f"{bitrate_kbps:.1f}" if bitrate_kbps is not None else "",
            encoder,
            software,
            creation_time,
            status,
        ])
PY
