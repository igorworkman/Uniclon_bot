import asyncio, logging, os, threading, time
from queue import Queue
import psutil
# REGION AI: smart render queue
render_queue, _STARTED = Queue(), threading.Event()

def _ensure_worker(_: asyncio.AbstractEventLoop) -> None:
    if _STARTED.is_set():
        return
    threading.Thread(target=_worker, name="smart-render", daemon=True).start(); _STARTED.set()

def _cpu_percent() -> float:
    try:
        return float(psutil.cpu_percent(interval=0.5))
    except Exception:
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
            while True:
                load = _cpu_percent()
                if load <= 85.0:
                    break
                logging.info("🕐 Waiting: CPU overloaded (%s%%)", int(load))
                time.sleep(5)
            logging.info("🚀 Start render: %s | CPU load=%s%%", video, int(load))
            payload["loop"].call_soon_threadsafe(payload["event"].set)
            payload["done"].wait()
            logging.info("✅ Completed: %s", video)

async def acquire_render_slot(video: str, copies: int, priority: int):
    loop = asyncio.get_running_loop()
    _ensure_worker(loop)
    start_event, done = asyncio.Event(), threading.Event()
    logging.info("🧩 Added to render queue: %s (priority=%s)", video, priority)
    render_queue.put((priority, time.monotonic(), {"video": video, "copies": copies, "loop": loop, "event": start_event, "done": done}))
    await start_event.wait()
    return done.set
# END REGION AI
