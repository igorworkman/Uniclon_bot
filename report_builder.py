import csv, json, logging
from pathlib import Path
from typing import Iterable, Optional, Tuple

from config import OUTPUT_DIR

# fix: модуль расчёта UniqScore
# REGION AI: uniqueness report builder
logger = logging.getLogger(__name__)


def _parse_float(value: object) -> Optional[float]:
    try:  # noqa: E701 - compact helpers для режима ≤50 строк
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None


def _percent_delta(bitrate: Optional[float], target: Optional[float]) -> Optional[float]:
    if bitrate is None or target in (None, 0):
        return None
    try:
        return abs((bitrate - target) / target * 100.0)
    except ZeroDivisionError:
        return None


def build_uniqueness_report(success_files: Iterable[str], total_copies: int) -> Optional[Tuple[dict, str, str]]:
    targets = {token for item in success_files if (text := str(item or "").strip()) for token in {text, Path(text).name} if token}
    if not targets:
        return None

    manifest_path = OUTPUT_DIR / "manifest.csv"
    if not manifest_path.exists():
        logger.warning("Manifest %s not found for uniqueness report", manifest_path)
        return None

    with manifest_path.open("r", encoding="utf-8") as manifest_file:
        rows = [
            row
            for row in csv.DictReader(manifest_file)
            if (filename := (row.get("filename") or row.get("file") or "").strip())
            and (filename in targets or Path(filename).name in targets)
        ]

    if not rows:
        logger.warning("No manifest rows found for %s", ", ".join(sorted(targets)))
        return None

    phash_vals = [
        abs(v)
        for row in rows
        if (v := _parse_float(row.get("phash_delta") or row.get("phash"))) is not None
    ]
    ssim_vals = [
        max(0.0, min(1.0, v))
        for row in rows
        if (v := _parse_float(row.get("ssim"))) is not None
    ]
    bitrate_diffs = [
        delta
        for row in rows
        if (delta := _percent_delta(
            _parse_float(row.get("bitrate")),
            _parse_float(row.get("target_bitrate") or row.get("bitrate_target")),
        ))
        is not None
    ]

    avg_phash = sum(phash_vals) / len(phash_vals) if phash_vals else 0.0
    avg_ssim = sum(ssim_vals) / len(ssim_vals) if ssim_vals else 1.0
    avg_bitrate_diff = sum(bitrate_diffs) / len(bitrate_diffs) if bitrate_diffs else 0.0

    score = min(100, round(avg_phash * 5 + (1 - avg_ssim) * 3000 + avg_bitrate_diff / 2))
    if score < 20:
        score = 20

    report = {
        "copies_total": int(total_copies),
        "copies_success": len(rows),
        "avg_phash": round(avg_phash, 2),
        "avg_ssim": round(avg_ssim, 3),
        "avg_bitrate_diff": round(avg_bitrate_diff, 1),
        "uniq_score": score,
        "diversified": score >= 76,
    }

    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    level_emoji = "🔴" if score <= 40 else ("🟠" if score <= 75 else "🟢")
    summary_line = (
        f"✅ UniqScore: {score} | ΔpHash={report['avg_phash']} | "
        f"SSIM={report['avg_ssim']} | ΔBR={report['avg_bitrate_diff']}%"
    )

    logger.info(summary_line)
    logger.info("📊 Уровень уникальности: %s", level_emoji)

    return report, summary_line, level_emoji
# END REGION AI
