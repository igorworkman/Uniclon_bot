# fix: Render Orchestrator v1
# REGION AI: orchestrator core
import asyncio, json, logging, queue, time
from itertools import count
from pathlib import Path
import psutil
logger = logging.getLogger(__name__); STATE_FILE = Path(__file__).resolve().parent / "orchestrator_state.json"; _cond = asyncio.Condition(); _render_q = queue.PriorityQueue(); _counter = count(); _active_id = None
try:
    _state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
except Exception:
    _state = {"history": [], "metrics": {}}
freq = psutil.cpu_freq() or type("F", (), {"max": 0})(); bench = {"cpu": getattr(freq, "max", 0.0), "cores": psutil.cpu_count(logical=False) or 0}
_state["bench"] = bench; metrics = _state.setdefault("metrics", {})
for key, default in (("UniqScore_avg", 0.0), ("SSIM_avg", 0.0), ("phash_avg", 0.0)):
    metrics.setdefault(key, default)
_save = lambda: STATE_FILE.write_text(json.dumps(_state, ensure_ascii=False, indent=2), encoding="utf-8")
_save(); logger.info("🧠 Benchmark: CPU %.1f GHz | %s cores", (bench["cpu"] or 0.0) / 1000, bench["cores"])
async def add_task(video, copies, priority=1):
    global _active_id
    tid = next(_counter); payload = {"id": tid, "video": video, "copies": copies}
    _render_q.put((priority, tid, payload)); logger.info("🧩 Task added: %s | priority=%s", video, priority)
    async with _cond:
        await _cond.wait_for(lambda: _render_q.queue and _render_q.queue[0][2]["id"] == tid and _active_id is None)
        _render_q.get(); _active_id = tid
    load = psutil.cpu_percent(interval=None) or 0.0
    while load > 85:
        time.sleep(5); load = psutil.cpu_percent(interval=None) or 0.0
    logger.info("🚀 Start render: %s | CPU load=%s%%", video, int(load))
    avg = metrics.get("UniqScore_avg", 0.0)
    if avg and avg < 60:
        mode, env = "boost", {"ADAPTIVE_ROTATE_RANGE": "1", "ADAPTIVE_VIGNETTE": "1"}
    elif avg and avg > 85:
        mode, env = "relax", {"ADAPTIVE_ROTATE_RANGE": "0", "ADAPTIVE_VIGNETTE": "0"}
    else:
        mode, env = "neutral", {}
    return {"id": tid, "video": video, "env": env, "mode": mode, "load": load}
async def finish_task(ticket, metrics_payload=None):
    global _active_id
    entry = {"video": ticket.get("video"), "ts": time.time()}
    if metrics_payload:
        entry.update({"UniqScore": float(metrics_payload.get("uniq_score", 0.0)), "SSIM": float(metrics_payload.get("avg_ssim", 0.0)), "phash": float(metrics_payload.get("avg_phash", 0.0))})
    history = _state.setdefault("history", []); history.append(entry); del history[:-20]
    for key, src, rnd in (("UniqScore_avg", "UniqScore", 1), ("SSIM_avg", "SSIM", 3), ("phash_avg", "phash", 2)):
        vals = [item.get(src) for item in history if isinstance(item.get(src), (int, float))]
        if vals:
            metrics[key] = round(sum(vals) / len(vals), rnd)
    _save(); logger.info("✅ Done | UniqScore=%s | Next task queued.", "-" if not metrics_payload else metrics_payload.get("uniq_score"))
    async with _cond:
        _active_id = None; _cond.notify_all()
# END REGION AI
