
import asyncio
import csv
import logging
import shlex
import time
from dataclasses import dataclass
from pathlib import Path
from statistics import mean
from typing import Awaitable, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

from dotenv import load_dotenv

from aiogram import Bot, Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer
from aiogram.exceptions import TelegramAPIError
from aiogram.filters import Command
from aiogram.types import Message
from aiohttp import ClientError

load_dotenv()

# REGION AI: local imports
from config import BOT_TOKEN, BOT_API_BASE, OUTPUT_DIR


BASE_DIR = Path(__file__).resolve().parent
CHECKS_DIR = BASE_DIR / "checks"
CHECKS_DIR.mkdir(parents=True, exist_ok=True)


@dataclass
class AuditSummary:
    copies_created: int
    bitrate_variation_pct: float
    mean_ssim: float
    mean_phash_diff: float
    trust_score: float
    manifest_path: Path
    report_path: Path
    source_name: str


async def run_shell(command: str, *, cwd: Optional[Path] = None) -> Tuple[int, str]:
    """Run shell command and capture output without raising on non-zero exit."""

    logger = logging.getLogger("uniclon.audit")
    proc = await asyncio.create_subprocess_shell(
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=str(cwd) if cwd else None,
    )

    output_parts: List[str] = []
    assert proc.stdout is not None
    async for chunk in proc.stdout:
        text = chunk.decode(errors="replace")
        output_parts.append(text)
        if text.strip():
            logger.info("[shell] %s", text.rstrip())

    rc = await proc.wait()
    return rc, "".join(output_parts)


def _ensure_executable(path: Path) -> None:
    try:
        mode = path.stat().st_mode
        path.chmod(mode | 0o111)
    except FileNotFoundError:
        logging.getLogger("uniclon.audit").warning("Audit helper %s is missing", path)
    except OSError as exc:
        logging.getLogger("uniclon.audit").warning(
            "Failed to chmod %s executable: %s", path, exc
        )


def _extract_float(values: Iterable[str]) -> List[float]:
    extracted: List[float] = []
    for value in values:
        try:
            extracted.append(float(value))
        except (TypeError, ValueError):
            continue
    return extracted


def _calculate_trust_score(
    mean_ssim: float,
    mean_phash: float,
    bitrate_variation: float,
    *,
    has_ssim: bool,
    has_phash: bool,
) -> float:
    score = 10.0
    if has_ssim and mean_ssim < 0.98:
        score -= min(4.5, (0.98 - mean_ssim) * 45)
    if has_phash and mean_phash < 18:
        score -= min(3.0, (18 - mean_phash) * 0.2)
    if bitrate_variation > 12:
        score -= min(2.5, (bitrate_variation - 12) * 0.1)
    return max(0.0, round(min(score, 10.0), 1))


async def perform_self_audit(
    source: Path,
    generated_files: Sequence[Path],
) -> Optional[AuditSummary]:
    """Run post-processing quality checks and return aggregated summary."""

    logger = logging.getLogger("uniclon.audit")
    base_dir = BASE_DIR

    scripts = [
        base_dir / "collect_meta.sh",
        base_dir / "quality_check.sh",
    ]
    for script in scripts:
        if script.exists():
            _ensure_executable(script)
            rc, _ = await run_shell(f"./{script.name}", cwd=base_dir)
            if rc != 0:
                logger.warning("Audit helper %s exited with %s", script.name, rc)
        else:
            logger.warning("Audit helper %s not found", script)

    video_path = source.resolve()
    pattern_files = {p.resolve() for p in OUTPUT_DIR.glob("*_final_v*.mp4")}
    seen = {p.resolve() for p in generated_files}
    to_process = sorted(pattern_files | seen)

    phash_script = base_dir / "phash_check.py"
    if phash_script.exists():
        _ensure_executable(phash_script)
        for candidate in to_process:
            cmd = "python3 phash_check.py {src} {dst}".format(
                src=shlex.quote(str(video_path)), dst=shlex.quote(str(candidate))
            )
            rc, _ = await run_shell(cmd, cwd=base_dir)
            if rc != 0:
                logger.warning("pHash check failed for %s (rc=%s)", candidate.name, rc)
    else:
        logger.warning("pHash checker %s not found", phash_script)

    audit_script = base_dir / "uniclon_audit.sh"
    if audit_script.exists():
        _ensure_executable(audit_script)
        rc, _ = await run_shell(f"./{audit_script.name}", cwd=base_dir)
        if rc != 0:
            logger.warning("Audit aggregator exited with %s", rc)
    else:
        logger.warning("Audit aggregator %s missing", audit_script)

    manifest_path = OUTPUT_DIR / "manifest.csv"
    report_path = CHECKS_DIR / "uniclon_report.csv"
    quality_path = CHECKS_DIR / "quality_summary.csv"
    phash_path = CHECKS_DIR / "phash_summary.csv"

    if not report_path.exists():
        logger.warning("Audit report %s not found", report_path)
        return None

    report_rows: List[Dict[str, str]] = []
    metrics_map: Dict[str, Dict[str, str]] = {}
    with report_path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            report_rows.append(row)
            name = (row.get("file") or row.get("filename") or "").strip()
            if name:
                metrics_map[name] = row

    target_names = {p.name for p in generated_files}
    if not target_names:
        target_names = set(metrics_map)

    mean_ssim = 0.0
    ssim_values: List[float] = []
    phash_values: List[float] = []
    bitrates: List[float] = []

    for name in target_names:
        row = metrics_map.get(name)
        if not row:
            continue
        ssim_values.extend(
            _extract_float([row.get("SSIM"), row.get("ssim")])
        )
        phash_values.extend(
            _extract_float([row.get("pHash"), row.get("phash"), row.get("phash_diff")])
        )
        bitrates.extend(
            _extract_float([row.get("bitrate"), row.get("bitrate_kbps")])
        )

    if not ssim_values and quality_path.exists():
        with quality_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                name = (row.get("file") or row.get("filename") or "").strip()
                if name and name in target_names:
                    ssim_values.extend(
                        _extract_float([row.get("SSIM"), row.get("ssim")])
                    )

    if not phash_values and phash_path.exists():
        with phash_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                name = (row.get("file") or row.get("filename") or "").strip()
                if name and name in target_names:
                    phash_values.extend(
                        _extract_float([row.get("phash_diff"), row.get("phash")])
                    )

    if ssim_values:
        mean_ssim = round(mean(ssim_values), 3)

    mean_phash = round(mean(phash_values), 1) if phash_values else 0.0

    bitrate_variation = 0.0
    if bitrates:
        avg_bitrate = sum(bitrates) / len(bitrates)
        if avg_bitrate > 0:
            deviation = sum(abs(b - avg_bitrate) for b in bitrates) / len(bitrates)
            bitrate_variation = round((deviation / avg_bitrate) * 100, 1)
        else:
            bitrate_variation = 0.0

    trust_score = _calculate_trust_score(
        mean_ssim,
        mean_phash,
        bitrate_variation,
        has_ssim=bool(ssim_values),
        has_phash=bool(phash_values),
    )

    return AuditSummary(
        copies_created=len(generated_files),
        bitrate_variation_pct=bitrate_variation,
        mean_ssim=mean_ssim,
        mean_phash_diff=mean_phash,
        trust_score=trust_score,
        manifest_path=manifest_path,
        report_path=report_path,
        source_name=source.name,
    )


from handlers import (
    cleanup_user_outputs,
    get_user_output_paths,
    router,
    set_task_queue,
)
# END REGION AI


@dataclass
class TaskInfo:
    task_id: int
    label: str
    status: str
    created_at: float
    started_at: Optional[float] = None
    profile: Optional[str] = None
    copies: Optional[int] = None
    save_preview: Optional[bool] = None


class UserTaskQueue:
    def __init__(self, per_user_limit: int = 1) -> None:
        self._per_user_limit = max(1, per_user_limit)
        self._queues: Dict[int, asyncio.Queue[Optional[Tuple[int, Callable[[], Awaitable[None]]]]]] = {}
        self._workers: Dict[int, List[asyncio.Task[None]]] = {}
        self._tasks: Dict[int, List[TaskInfo]] = {}
        self._lock = asyncio.Lock()
        self._closed = False
        self._idle_timeout = 5.0
        self._task_counter = 0

    async def enqueue(
        self,
        user_id: int,
        task_factory: Callable[[], Awaitable[None]],
        label: str,
        *,
        profile: Optional[str] = None,
        copies: Optional[int] = None,
        save_preview: Optional[bool] = None,
    ) -> None:
        if self._closed:
            raise RuntimeError("Task queue is shutting down")
        async with self._lock:
            queue = self._queues.setdefault(user_id, asyncio.Queue())
            workers = self._workers.setdefault(user_id, [])
            self._task_counter += 1
            task_id = self._task_counter
            self._tasks.setdefault(user_id, []).append(
                TaskInfo(
                    task_id=task_id,
                    label=label,
                    status="pending",
                    created_at=time.time(),
                    profile=profile,
                    copies=copies,
                    save_preview=save_preview,
                )
            )
            await queue.put((task_id, task_factory))
            while len(workers) < self._per_user_limit:
                workers.append(asyncio.create_task(self._worker(user_id, queue)))

    async def close(self) -> None:
        self._closed = True
        async with self._lock:
            snapshot = [
                (uid, self._queues[uid], list(self._workers.get(uid, []))) for uid in list(self._queues)
            ]
        for uid, queue, workers in snapshot:
            for _ in workers:
                await queue.put(None)
            self._tasks.pop(uid, None)
        tasks = [task for _, _, workers in snapshot for task in workers]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _worker(
        self,
        user_id: int,
        queue: asyncio.Queue[Optional[Tuple[int, Callable[[], Awaitable[None]]]]],
    ) -> None:
        try:
            while True:
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=self._idle_timeout)
                except asyncio.TimeoutError:
                    break
                if payload is None:
                    queue.task_done()
                    break
                task_id, task_factory = payload
                async with self._lock:
                    for info in self._tasks.get(user_id, []):
                        if info.task_id == task_id:
                            info.status = "active"
                            info.started_at = time.time()
                            break
                try:
                    await task_factory()
                except Exception:  # noqa: BLE001
                    logging.exception("Queued task for user %s failed", user_id)
                finally:
                    queue.task_done()
                    async with self._lock:
                        tasks = self._tasks.get(user_id, [])
                        remaining = [info for info in tasks if info.task_id != task_id]
                        if remaining:
                            self._tasks[user_id] = remaining
                        else:
                            self._tasks.pop(user_id, None)
        finally:
            async with self._lock:
                workers = self._workers.get(user_id, [])
                try:
                    workers.remove(asyncio.current_task())
                except ValueError:
                    pass
                if not workers:
                    self._workers.pop(user_id, None)
                    self._queues.pop(user_id, None)
                    self._tasks.pop(user_id, None)

    async def get_user_tasks(self, user_id: int) -> List[TaskInfo]:
        async with self._lock:
            return list(self._tasks.get(user_id, []))


_TASK_QUEUE_REF: Optional["UserTaskQueue"] = None


def set_task_queue_reference(queue: Optional["UserTaskQueue"]) -> None:
    global _TASK_QUEUE_REF
    _TASK_QUEUE_REF = queue


async def handle_clean_command(message: Message) -> None:
    if not message.from_user:
        return

    user_id = message.from_user.id
    keep_newer_than: Optional[float] = None
    queue = _TASK_QUEUE_REF
    if queue is not None:
        tasks = await queue.get_user_tasks(user_id)
        active_starts = [info.started_at for info in tasks if info.status == "active"]
        active_starts = [ts for ts in active_starts if ts]
        if active_starts:
            guard_window = 30.0
            keep_newer_than = max(0.0, min(active_starts) - guard_window)

    existing = get_user_output_paths(user_id)
    if existing:
        removed, skipped = cleanup_user_outputs(user_id, keep_newer_than=keep_newer_than)
        logging.info(
            "Manual clean for user=%s removed=%s skipped=%s", user_id, removed, skipped
        )
    else:
        # ensure registry cleanup even if no files are tracked
        cleanup_user_outputs(user_id, keep_newer_than=keep_newer_than)

    await message.answer("🧹 Старые копии удалены.")


def make_bot() -> Bot:
    if BOT_API_BASE:
        session = AiohttpSession(api=TelegramAPIServer.from_base(BOT_API_BASE))
        return Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"), session=session)
    return Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"))


def make_dispatcher() -> Dispatcher:
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)
    dp.message.register(handle_clean_command, Command("clean"))
    return dp


async def run_polling() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(name)s: %(message)s")
    bot = None
    task_queue: Optional[UserTaskQueue] = None
    try:
        bot = make_bot()
        dp = make_dispatcher()
        logging.info("Outputs and manifest stored in %s", OUTPUT_DIR)
        task_queue = UserTaskQueue()
        set_task_queue(task_queue)
        set_task_queue_reference(task_queue)
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    except (TelegramAPIError, ClientError, ValueError) as exc:
        logging.exception("Failed to start polling due to invalid token or API configuration: %s", exc)
        raise
    finally:
        if bot and bot.session:
            await bot.session.close()
        if task_queue:
            await task_queue.close()
        set_task_queue_reference(None)


if __name__ == "__main__":
    try:
        asyncio.run(run_polling())
    except (KeyboardInterrupt, SystemExit):
        logging.info("Bot shutdown requested. Exiting gracefully.")
