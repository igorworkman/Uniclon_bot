import asyncio, logging, os, threading, time
from queue import Queue

try:
    import psutil  # type: ignore
except ImportError:  # pragma: no cover - optional dependency
    psutil = None
# REGION AI: smart render queue
render_queue, _STARTED = Queue(), threading.Event()

def _ensure_worker(_: asyncio.AbstractEventLoop) -> None:
    if _STARTED.is_set():
        return
    threading.Thread(target=_worker, name="smart-render", daemon=True).start(); _STARTED.set()

def _cpu_percent() -> float:
    if psutil is not None:
        try:
            return float(psutil.cpu_percent(interval=0.5))
        except Exception:
            pass
    try:
        load = os.getloadavg()[0]; cores = os.cpu_count() or 1
        return float(load / cores * 100.0)
    except Exception:
        return 0.0

def _worker() -> None:
    import heapq
    heap = []
    while True:
        heapq.heappush(heap, render_queue.get())
        while heap:
            _, _, payload = heapq.heappop(heap)
            video = payload["video"]
            if payload["done"].is_set():
                if payload.get("cancelled") and payload["cancelled"].is_set():
                    logging.info("⏭️ Skipped render: %s (cancelled)", video)
                else:
                    logging.info("⏭️ Skipped render: %s", video)
                continue
            while True:
                load = _cpu_percent()
                if load <= 85.0:
                    break
                logging.info("🕐 Waiting: CPU overloaded (%s%%)", int(load))
                time.sleep(5)
            logging.info("🚀 Start render: %s | CPU load=%s%%", video, int(load))
            payload["loop"].call_soon_threadsafe(payload["event"].set)
            while not payload["done"].wait(timeout=5):
                if payload.get("cancelled") and payload["cancelled"].is_set():
                    break
            if payload.get("cancelled") and payload["cancelled"].is_set():
                logging.info("⚠️ Cancelled: %s", video)
            else:
                logging.info("✅ Completed: %s", video)

async def acquire_render_slot(video: str, copies: int, priority: int):
    loop = asyncio.get_running_loop()
    _ensure_worker(loop)
    start_event, done = asyncio.Event(), threading.Event()
    cancelled = threading.Event()
    current_task = asyncio.current_task()

    if current_task is not None:
        def _auto_release(task: asyncio.Task) -> None:
            if task.cancelled():
                logging.info("⚠️ Render task cancelled: %s", video)
                cancelled.set()
            elif task.exception() is not None:
                logging.info("⚠️ Render task aborted: %s", video)
            done.set()

        current_task.add_done_callback(_auto_release)
    logging.info("🧩 Added to render queue: %s (priority=%s)", video, priority)
    render_queue.put((
        priority,
        time.monotonic(),
        {
            "video": video,
            "copies": copies,
            "loop": loop,
            "event": start_event,
            "done": done,
            "cancelled": cancelled,
        },
    ))
    await start_event.wait()

    def _release() -> None:
        if not done.is_set():
            done.set()

    return _release
# END REGION AI
