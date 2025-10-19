#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${BASE_DIR}/Новая папка"
MANIFEST="${OUTPUT_DIR}/manifest.csv"
CHECK_DIR="${BASE_DIR}/checks"
mkdir -p "${CHECK_DIR}"

python3 - "$MANIFEST" "${CHECK_DIR}/meta_summary.csv" <<'PY'
import csv
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
output_path.parent.mkdir(parents=True, exist_ok=True)

with output_path.open("w", encoding="utf-8", newline="") as out_file:
    writer = csv.writer(out_file)
    writer.writerow(["file", "encoder", "software", "creation_time"])
    if not manifest_path.exists():
        sys.exit(0)

    with manifest_path.open("r", encoding="utf-8", newline="") as manifest:
        reader = csv.DictReader(manifest)
        for row in reader:
            name = (row.get("filename") or row.get("file") or "").strip()
            if not name:
                continue
            encoder = (row.get("encoder") or row.get("ENCODER") or "").strip()
            software = (row.get("software") or row.get("SOFTWARE") or "").strip()
            creation_time = (row.get("creation_time") or row.get("creation-time") or "").strip()
            writer.writerow([name, encoder, software, creation_time])
PY
