#!/usr/bin/env python3
import csv
import math
import pathlib
import statistics
import subprocess
import sys
from typing import Dict

FRAME_SIZE = 32


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


def _dct_1d(vector):
    n = len(vector)
    factor = math.pi / (2 * n)
    scale0 = math.sqrt(1 / n)
    scale = math.sqrt(2 / n)
    result = []
    for k in range(n):
        acc = 0.0
        for idx, value in enumerate(vector):
            acc += value * math.cos((2 * idx + 1) * k * factor)
        result.append((scale0 if k == 0 else scale) * acc)
    return result


def _dct_2d(matrix):
    temp = [_dct_1d(row) for row in matrix]
    transposed = list(zip(*temp))
    return [
        list(vals)
        for vals in zip(*(_dct_1d(list(col)) for col in transposed))
    ]


def _phash(frame_bytes: bytes) -> int:
    matrix = [
        [frame_bytes[i * FRAME_SIZE + j] for j in range(FRAME_SIZE)]
        for i in range(FRAME_SIZE)
    ]
    dct_matrix = _dct_2d(matrix)
    top_left = [
        dct_matrix[i][j]
        for i in range(8)
        for j in range(8)
    ]
    median = statistics.median(top_left[1:]) if len(top_left) > 1 else 0.0
    bits = 0
    for value in top_left:
        bits = (bits << 1) | (1 if value > median else 0)
    return bits & ((1 << 64) - 1)


def _hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def _update_summary(target: pathlib.Path, diff: int) -> None:
    base_dir = pathlib.Path(__file__).resolve().parent
    summary_path = base_dir / "checks" / "phash_summary.csv"
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    entries: Dict[str, int] = {}
    if summary_path.exists():
        with summary_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                name = (row.get("file") or row.get("filename") or "").strip()
                if name:
                    try:
                        entries[name] = int(float(row.get("phash_diff", "0")))
                    except ValueError:
                        continue

    entries[target.name] = diff

    with summary_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["file", "phash_diff"])
        for name in sorted(entries):
            writer.writerow([name, entries[name]])


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: phash_check.py <original_video> <processed_video>", file=sys.stderr)
        return 1

    src = pathlib.Path(sys.argv[1]).expanduser()
    dst = pathlib.Path(sys.argv[2]).expanduser()

    if not src.exists():
        print(f"Source not found: {src}", file=sys.stderr)
        return 1
    if not dst.exists():
        print(f"Target not found: {dst}", file=sys.stderr)
        return 1

    try:
        src_frame = _read_frame(src)
        dst_frame = _read_frame(dst)
        src_hash = _phash(src_frame)
        dst_hash = _phash(dst_frame)
        diff = _hamming(src_hash, dst_hash)
    except Exception as exc:  # noqa: BLE001
        print(f"pHash calculation failed: {exc}", file=sys.stderr)
        return 1

    try:
        _update_summary(dst, diff)
    except Exception as exc:  # noqa: BLE001
        print(f"Failed to update summary: {exc}", file=sys.stderr)
        return 1

    print(f"{dst.name}: pHash diff = {diff}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
