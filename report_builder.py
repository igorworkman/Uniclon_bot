import csv, json, logging
from pathlib import Path
from typing import Iterable, Optional, Tuple
from config import OUTPUT_DIR
# fix: модуль расчёта UniqScore
# REGION AI: uniqueness report builder
logger = logging.getLogger(__name__)

def _parse_float(value: object) -> Optional[float]:
    try: return float(str(value).replace(",", "."))
    except (TypeError, ValueError): return None

def build_uniqueness_report(success_files: Iterable[str], total_copies: int) -> Optional[Tuple[dict, str]]:
    targets = {token for item in success_files if (text := str(item or "").strip()) for token in {text, Path(text).name} if token}
    if not targets: return None
    manifest_path = OUTPUT_DIR / "manifest.csv"
    if not manifest_path.exists(): logger.warning("Manifest %s not found for uniqueness report", manifest_path); return None
    rows = [row for row in csv.DictReader(manifest_path.open("r", encoding="utf-8")) if (filename := (row.get("filename") or row.get("file") or "").strip()) and (filename in targets or Path(filename).name in targets)]
    if not rows: logger.warning("No manifest rows found for %s", ", ".join(sorted(targets))); return None
    phash_vals = [abs(v) for row in rows if (v := _parse_float(row.get("phash_delta") or row.get("phash"))) is not None]
    ssim_vals = [max(0.0, min(1.0, v)) for row in rows if (v := _parse_float(row.get("ssim"))) is not None]
    bitrate_diffs = [abs(br - target) for row in rows if (br := _parse_float(row.get("bitrate"))) is not None and (target := _parse_float(row.get("target_bitrate"))) is not None]
    avg_phash = sum(phash_vals) / len(phash_vals) if phash_vals else 0.0
    avg_ssim = sum(ssim_vals) / len(ssim_vals) if ssim_vals else 1.0
    avg_bitrate = sum(bitrate_diffs) / len(bitrate_diffs) if bitrate_diffs else 0.0
    score = max(20, min(100, round(avg_phash * 5 + (1 - avg_ssim) * 3000 + avg_bitrate / 2)))
    report = {"copies_total": int(total_copies), "copies_success": len(rows), "avg_phash": round(avg_phash, 2), "avg_ssim": round(avg_ssim, 3), "avg_bitrate_diff": round(avg_bitrate, 1), "uniq_score": score, "diversified": score >= 60}
    report_path = OUTPUT_DIR / "report.json"; report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    emoji = "🔴" if score < 40 else ("🟠" if score < 70 else "🟢")
    trend = f"{emoji} UniqScore={score} | ΔpHash={report['avg_phash']} | SSIM={report['avg_ssim']} | Δbitrate={report['avg_bitrate_diff']}"
    logger.info("📊 %s | 📁 %s", trend, report_path)
    return report, trend
# END REGION AI
