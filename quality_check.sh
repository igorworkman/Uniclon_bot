#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${BASE_DIR}/Новая папка"
MANIFEST="${OUTPUT_DIR}/manifest.csv"
CHECK_DIR="${BASE_DIR}/checks"
mkdir -p "${CHECK_DIR}"

python3 - "$MANIFEST" "${CHECK_DIR}/quality_summary.csv" <<'PY'
import csv
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
output_path.parent.mkdir(parents=True, exist_ok=True)

with output_path.open("w", encoding="utf-8", newline="") as out_file:
    writer = csv.writer(out_file)
    writer.writerow(["file", "SSIM", "PSNR"])
    if not manifest_path.exists():
        sys.exit(0)

    with manifest_path.open("r", encoding="utf-8", newline="") as manifest:
        reader = csv.DictReader(manifest)
        for row in reader:
            name = (row.get("filename") or row.get("file") or "").strip()
            if not name:
                continue
            ssim = (row.get("ssim") or row.get("SSIM") or "").strip()
            psnr = (row.get("psnr") or row.get("PSNR") or "").strip()
            writer.writerow([name, ssim, psnr])
PY
