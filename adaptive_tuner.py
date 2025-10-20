from __future__ import annotations
import json, time
from pathlib import Path
from typing import Dict, List, Tuple
HISTORY_FILE = Path(__file__).resolve().parent / "adaptive_history.json"
HISTORY_LIMIT = 20
# fix: adaptive tuner storage
# REGION AI: adaptive tuning helpers
def _load_history() -> List[Dict[str, float]]:
    if not HISTORY_FILE.exists():
        return []
    try:
        payload = json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    items = payload.get("history") or []
    return [item for item in items if isinstance(item, dict)]
def _save_history(history: List[Dict[str, float]]) -> None:
    HISTORY_FILE.write_text(json.dumps({"history": history[-HISTORY_LIMIT:]}, ensure_ascii=False, indent=2), encoding="utf-8")
def get_tuned_params() -> Tuple[Dict[str, str], Dict[str, float]]:
    history = _load_history()
    recent = [entry.get("uniq_score") for entry in history if isinstance(entry.get("uniq_score"), (int, float))][-5:]
    uniq_avg = sum(recent) / len(recent) if len(recent) >= 3 else None
    mode = "neutral"
    env: Dict[str, str] = {}
    if uniq_avg is not None and uniq_avg < 60:
        mode = "boost"
        env.update({"ADAPTIVE_ROTATE_RANGE": "1", "ADAPTIVE_VIGNETTE": "1", "ADAPTIVE_CURVES": "1"})
    elif uniq_avg is not None and uniq_avg > 85:
        mode = "relax"
        env.update({"ADAPTIVE_ROTATE_RANGE": "0", "ADAPTIVE_VIGNETTE": "0", "ADAPTIVE_CURVES": "0"})
    return env, {"mode": mode, "uniq_avg": uniq_avg}
def record_render_result(metrics: Dict[str, float]) -> None:
    entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "uniq_score": float(metrics.get("uniq_score", 0.0)),
        "avg_ssim": float(metrics.get("avg_ssim", 0.0)),
        "avg_phash": float(metrics.get("avg_phash", 0.0)),
        "avg_bitrate_diff": float(metrics.get("avg_bitrate_diff", 0.0)),
    }
    history = _load_history()
    history.append(entry)
    _save_history(history)
# END REGION AI
