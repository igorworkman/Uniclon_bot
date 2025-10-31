import csv
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from config import CHECKS_DIR

logger = logging.getLogger(__name__)

QC_MIN_REQUIRED_COPIES = max(1, int(os.getenv("UNICLON_QC_MIN_REQUIRED", "2")))


def _parse_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text in {"NA", "N/A", "None"}:
        return None
    text = text.replace(",", ".")
    try:
        return float(text)
    except ValueError:
        return None


@dataclass
class CopyQCResult:
    name: str
    status: str = "ok"
    ssim: Optional[float] = None
    psnr: Optional[float] = None
    phash: Optional[float] = None
    bitrate: Optional[float] = None

    def has_invalid_metrics(self) -> bool:
        if self.status.lower() == "error":
            return True
        critical_metrics = [self.ssim, self.psnr, self.bitrate]
        for value in critical_metrics:
            if value is None or value <= 0:
                return True
        if self.phash is not None and self.phash <= 0:
            return True
        return False

    def normalize_status(self) -> None:
        normalized = (self.status or "").strip().lower()
        if not normalized:
            normalized = "ok"
        if normalized not in {"ok", "error", "low_quality"}:
            normalized = "ok"
        if self.has_invalid_metrics():
            normalized = "error"
        self.status = normalized

    def is_valid(self) -> bool:
        self.normalize_status()
        return self.status != "error"

    def metrics_for_log(self) -> str:
        def _fmt(value: Optional[float], precision: int = 3) -> str:
            if value is None:
                return "n/a"
            fmt = f"{{:.{precision}f}}"
            return fmt.format(value)

        return (
            f"SSIM={_fmt(self.ssim)}"
            f", PSNR={_fmt(self.psnr, precision=2)}"
            f", pHash={_fmt(self.phash, precision=2)}"
            f", bitrate={_fmt(self.bitrate, precision=0)}"
        )


def load_qc_report(report_path: Optional[Path] = None) -> Dict[str, CopyQCResult]:
    target_path = report_path or (CHECKS_DIR / "uniclon_report.csv")
    if not target_path.exists():
        logger.debug("QC report %s not found", target_path)
        return {}

    results: Dict[str, CopyQCResult] = {}
    try:
        with target_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                raw_name = (
                    row.get("copy")
                    or row.get("file")
                    or row.get("filename")
                    or ""
                ).strip()
                if not raw_name:
                    continue
                name = Path(raw_name).name
                result = CopyQCResult(
                    name=name,
                    status=(row.get("status") or row.get("verdict") or "").strip(),
                    ssim=_parse_float(row.get("ssim") or row.get("SSIM")),
                    psnr=_parse_float(row.get("psnr") or row.get("PSNR")),
                    phash=_parse_float(row.get("phash") or row.get("pHash") or row.get("phash_diff")),
                    bitrate=_parse_float(row.get("bitrate") or row.get("bitrate_kbps")),
                )
                result.normalize_status()
                results[name] = result
    except Exception:  # noqa: BLE001
        logger.exception("Failed to parse QC report %s", target_path)
        return {}

    return results
