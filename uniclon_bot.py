
import asyncio
import csv
import logging
import os
import shlex
import time
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from statistics import mean
from typing import Awaitable, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

from dotenv import load_dotenv

from aiogram import Bot, Dispatcher
from aiogram.exceptions import TelegramAPIError
from aiogram.filters import Command
from aiogram.types import Message
from aiohttp import ClientError

load_dotenv()

# REGION AI: local imports
from loader import bot as loader_bot, dp as loader_dp


BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = Path("output")
if not OUTPUT_DIR.is_absolute():
    OUTPUT_DIR = (BASE_DIR / OUTPUT_DIR).resolve()
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("OUTPUT_DIR", str(OUTPUT_DIR))
CHECKS_DIR = BASE_DIR / "checks"
CHECKS_DIR.mkdir(parents=True, exist_ok=True)


logger = logging.getLogger(__name__)


async def periodic_preview_scan(interval: int = 120):
    from utils import BASE_DIR as _base_dir, CHECKS_DIR as _utils_checks_dir  # noqa: F401

    while True:
        flags = (CHECKS_DIR / "preview_flags").glob("*.flag")
        for flag in flags:
            stem = flag.stem
            previews = list((CHECKS_DIR / "previews").glob(f"{stem}*.png"))
            if previews:
                logger.info("[Preview] Confirmed for %s (%d found)", stem, len(previews))
                flag.unlink(missing_ok=True)
        await asyncio.sleep(interval)


@dataclass
class AuditSummary:
    copies_created: int
    avg_bitrate_kbps: float
    avg_bitrate_mbps: float
    mean_ssim: float
    mean_psnr: float
    mean_phash_diff: float
    trust_score: float
    manifest_path: Path
    report_path: Path
    source_name: str
    status_warnings: List[str]
    encoder_diversified: bool
    timestamps_randomized: bool
    phash_ok: bool
    metadata_sanitized: bool
    trust_label: str
    trust_emoji: str
    profile_label: Optional[str]
    bitrate_variation_pct: float
    low_uniqueness_fallback: bool
    low_uniqueness_message: Optional[str]


async def run_shell(command: str, *, cwd: Optional[Path] = None) -> Tuple[int, str]:
    """Run shell command and capture output without raising on non-zero exit."""

    logger = logging.getLogger("uniclon.audit")
    env = os.environ.copy()
    env.setdefault("OUTPUT_DIR", str(OUTPUT_DIR))

    proc = await asyncio.create_subprocess_shell(
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=str(cwd) if cwd else None,
        env=env,
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


def _parse_iso_datetime(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    candidate = value.strip()
    if not candidate:
        return None
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(candidate)
    except ValueError:
        return None


def _calculate_trust_score(
    mean_ssim: float,
    mean_phash: float,
    mean_psnr: float,
    bitrate_variation: float,
    *,
    has_ssim: bool,
    has_phash: bool,
    has_psnr: bool,
) -> float:
    score = 10.0
    if has_ssim and mean_ssim < 0.96:
        score -= min(4.0, (0.96 - mean_ssim) * 50)
    if has_psnr and mean_psnr < 37.0:
        score -= min(2.5, (37.0 - mean_psnr) * 0.25)
    if has_phash and mean_phash < 10.0:
        score -= min(3.0, (10.0 - mean_phash) * 0.3)
    if bitrate_variation < 4.0:
        score -= min(1.5, (4.0 - bitrate_variation) * 0.2)
    elif bitrate_variation > 18.0:
        score -= min(1.5, (bitrate_variation - 18.0) * 0.1)
    return max(0.0, round(min(score, 10.0), 1))


def _derive_trust_label(score: float, profile_label: Optional[str]) -> Tuple[str, str]:
    if score >= 8.5:
        base = "Safe"
        emoji = "✅"
    elif score >= 6.5:
        base = "Review"
        emoji = "⚠️"
    else:
        base = "High risk"
        emoji = "❌"

    if profile_label:
        if base == "Safe":
            label = f"Safe for {profile_label}"
        elif base == "Review":
            label = f"Review before posting to {profile_label}"
        else:
            label = f"High risk on {profile_label}"
    else:
        if base == "Safe":
            label = "Ready for upload"
        elif base == "Review":
            label = "Review manually before upload"
        else:
            label = "Needs rework before publishing"

    return label, emoji


async def _perform_self_audit_impl(
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

    phash_log_path = CHECKS_DIR / "phash_raw.log"
    try:
        phash_log_path.write_text("", encoding="utf-8")
    except OSError as exc:
        logger.debug("Failed to reset pHash log: %s", exc)

    video_path = source.resolve()
    to_process = [p.resolve() for p in generated_files if p.suffix.lower() == ".mp4"]

    phash_script = base_dir / "phash_check.py"
    if phash_script.exists():
        _ensure_executable(phash_script)
        log_target = shlex.quote(str(phash_log_path))
        for candidate in to_process:
            cmd = "python3 phash_check.py {src} {dst} >> {log} 2>&1".format(
                src=shlex.quote(str(video_path)),
                dst=shlex.quote(str(candidate)),
                log=log_target,
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
    fallback_flag = CHECKS_DIR / "low_uniqueness.flag"

    fallback_triggered = False
    fallback_message = "⚠️ Low uniqueness fallback triggered."
    if fallback_flag.exists():
        fallback_triggered = True
        try:
            raw = fallback_flag.read_text(encoding="utf-8").strip()
            if raw:
                fallback_message = raw
        except OSError as exc:
            logger.debug("Failed to read fallback flag: %s", exc)
        try:
            fallback_flag.unlink()
        except OSError as exc:
            logger.debug("Failed to remove fallback flag: %s", exc)

    if not report_path.exists():
        logger.warning("Audit report %s not found", report_path)
        return None

    report_rows: List[Dict[str, str]] = []
    metrics_map: Dict[str, Dict[str, str]] = {}
    with report_path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            report_rows.append(row)
            name = (
                row.get("file")
                or row.get("filename")
                or row.get("copy")
                or ""
            ).strip()
            if name:
                metrics_map[name] = row

    target_names = {p.name for p in generated_files if p.suffix.lower() == ".mp4"}
    if not target_names:
        target_names = set(metrics_map)

    ssim_values: List[float] = []
    psnr_values: List[float] = []
    phash_values: List[float] = []
    bitrate_values: List[float] = []
    statuses: List[str] = []
    encoder_pairs: List[Tuple[str, str]] = []
    creation_values: List[str] = []
    invalid_metrics_detected = False

    for name in target_names:
        row = metrics_map.get(name)
        if not row:
            continue
        status_raw = (row.get("status") or row.get("verdict") or "").strip()
        if status_raw:
            statuses.append(status_raw)
        ssim_data = _extract_float([row.get("SSIM"), row.get("ssim")])
        psnr_data = _extract_float([row.get("PSNR"), row.get("psnr")])
        phash_data = _extract_float([row.get("pHash"), row.get("phash"), row.get("phash_diff")])
        bitrate_data = _extract_float([row.get("bitrate_kbps"), row.get("bitrate")])

        ssim_value = ssim_data[0] if ssim_data else None
        psnr_value = psnr_data[0] if psnr_data else None
        phash_value = phash_data[0] if phash_data else None
        bitrate_value = bitrate_data[0] if bitrate_data else None

        metrics_invalid = False
        if status_raw.strip().lower() == "error":
            metrics_invalid = True
        if ssim_value is None or ssim_value <= 0:
            metrics_invalid = True
        if psnr_value is None or psnr_value <= 0:
            metrics_invalid = True
        if bitrate_value is None or bitrate_value <= 0:
            metrics_invalid = True
        if phash_value is not None and phash_value <= 0:
            metrics_invalid = True

        if metrics_invalid:
            invalid_metrics_detected = True
            if not status_raw:
                statuses.append("error")
        else:
            if ssim_value is not None:
                ssim_values.append(ssim_value)
            if psnr_value is not None:
                psnr_values.append(psnr_value)
            if phash_value is not None:
                phash_values.append(phash_value)
            if bitrate_value is not None:
                value = bitrate_value
                if value > 100000:
                    value /= 1000.0
                bitrate_values.append(value)
        encoder_pairs.append((row.get("encoder") or "", row.get("software") or ""))
        creation_values.append(row.get("creation_time") or "")

    if not ssim_values and quality_path.exists():
        with quality_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                name = (row.get("file") or row.get("filename") or row.get("copy") or "").strip()
                if name and name in target_names:
                    ssim_data = _extract_float([row.get("SSIM"), row.get("ssim")])
                    if ssim_data and ssim_data[0] > 0:
                        ssim_values.append(ssim_data[0])
                    psnr_data = _extract_float([row.get("PSNR"), row.get("psnr")])
                    if psnr_data and psnr_data[0] > 0:
                        psnr_values.append(psnr_data[0])

    if not phash_values and phash_path.exists():
        with phash_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                name = (row.get("file") or row.get("filename") or row.get("copy") or "").strip()
                if name and name in target_names:
                    phash_data = _extract_float([row.get("phash_diff"), row.get("phash")])
                    if phash_data and phash_data[0] > 0:
                        phash_values.append(phash_data[0])

    mean_ssim = round(mean(ssim_values), 3) if ssim_values else 0.0
    mean_psnr = round(mean(psnr_values), 1) if psnr_values else 0.0
    mean_phash = round(mean(phash_values), 1) if phash_values else 0.0

    avg_bitrate_kbps = 0.0
    if bitrate_values:
        avg_bitrate_kbps = sum(bitrate_values) / len(bitrate_values)
    avg_bitrate_mbps = round(avg_bitrate_kbps / 1000.0, 1) if avg_bitrate_kbps else 0.0

    bitrate_variation = 0.0
    if bitrate_values and avg_bitrate_kbps > 0:
        deviation = sum(abs(b - avg_bitrate_kbps) for b in bitrate_values) / len(bitrate_values)
        bitrate_variation = round((deviation / avg_bitrate_kbps) * 100, 1)

    status_warnings: List[str] = []
    for status in statuses:
        normalized = (status or "").strip()
        if not normalized:
            continue
        lower = normalized.lower()
        if "warning" in lower or lower in {"low_quality", "error"}:
            if normalized not in status_warnings:
                status_warnings.append(normalized)
    if fallback_triggered and fallback_message not in status_warnings:
        status_warnings.append(fallback_message)

    encoder_combos = {
        (enc.strip().lower(), soft.strip().lower())
        for enc, soft in encoder_pairs
        if enc or soft
    }
    encoder_diversified = len(encoder_combos) > 1

    creation_datetimes = [dt for dt in (_parse_iso_datetime(value) for value in creation_values) if dt]
    if len(creation_datetimes) <= 1:
        timestamps_randomized = bool(creation_datetimes)
    else:
        unique_times = {dt.isoformat() for dt in creation_datetimes}
        time_span = (max(creation_datetimes) - min(creation_datetimes)).total_seconds()
        timestamps_randomized = len(unique_times) > 1 or time_span >= 60

    phash_ok = mean_phash >= 10.0

    profile_label: Optional[str] = None
    # REGION AI: audit profile labels
    profile_map = {
        "tiktok": "TikTok",
        "instagram": "Instagram",
        "youtube": "YouTube Shorts",
    }
    # END REGION AI
    if manifest_path.exists():
        try:
            with manifest_path.open("r", encoding="utf-8", newline="") as fh:
                reader = csv.DictReader(fh)
                for row in reader:
                    file_name = (row.get("filename") or row.get("file") or "").strip()
                    if target_names and file_name and file_name not in target_names:
                        continue
                    raw_profile = (row.get("profile") or "").strip()
                    if raw_profile:
                        profile_label = profile_map.get(raw_profile.lower(), raw_profile)
                        break
        except Exception as exc:
            logger.debug("Failed to parse profile info: %s", exc)

    trust_score = _calculate_trust_score(
        mean_ssim,
        mean_phash,
        mean_psnr,
        bitrate_variation,
        has_ssim=bool(ssim_values),
        has_phash=bool(phash_values),
        has_psnr=bool(psnr_values),
    )

    if invalid_metrics_detected and trust_score > 5.0:
        adjusted_score = min(trust_score, 5.0)
        if adjusted_score < trust_score:
            logger.info(
                "[QC] TrustScore adjusted: %.1f → %.1f (invalid metrics)",
                trust_score,
                adjusted_score,
            )
            trust_score = adjusted_score

    trust_label, trust_emoji = _derive_trust_label(trust_score, profile_label)

    copies_created = len(target_names) if target_names else len(generated_files)
    if copies_created == 0:
        copies_created = len(metrics_map)

    return AuditSummary(
        copies_created=copies_created,
        avg_bitrate_kbps=round(avg_bitrate_kbps, 1) if avg_bitrate_kbps else 0.0,
        avg_bitrate_mbps=avg_bitrate_mbps,
        mean_ssim=mean_ssim,
        mean_psnr=mean_psnr,
        mean_phash_diff=mean_phash,
        trust_score=trust_score,
        manifest_path=manifest_path,
        report_path=report_path,
        source_name=source.name,
        status_warnings=status_warnings,
        encoder_diversified=encoder_diversified,
        timestamps_randomized=timestamps_randomized,
        phash_ok=phash_ok,
        metadata_sanitized=True,
        trust_label=trust_label,
        trust_emoji=trust_emoji,
        profile_label=profile_label,
        bitrate_variation_pct=bitrate_variation,
        low_uniqueness_fallback=fallback_triggered,
        low_uniqueness_message=fallback_message if fallback_triggered else None,
    )


# REGION AI: handlers imports
from utils import cleanup_user_outputs
from handlers import (
    get_user_output_paths,
    router,
    set_task_queue,
    handle_video,
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
    quality: Optional[str] = None


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
        quality: Optional[str] = None,
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
                    quality=quality,
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
                task_info: Optional[TaskInfo] = None
                async with self._lock:
                    for info in self._tasks.get(user_id, []):
                        if info.task_id == task_id:
                            info.status = "active"
                            info.started_at = time.time()
                            task_info = info
                            break
                if task_info:
                    # REGION AI: worker logging
                    logging.info(
                        "🚀 Исполнение: user=%s | video=%s | copies=%s | profile=%s | q=%s",
                        user_id,
                        task_info.label,
                        task_info.copies if task_info.copies is not None else "-",
                        task_info.profile or "-",
                        task_info.quality or "-",
                    )
                    # END REGION AI
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
    return loader_bot


def make_dispatcher() -> Dispatcher:
    dp = loader_dp
    if getattr(make_dispatcher, "_configured", False):
        return dp
    dp.include_router(router)
    dp.message.register(handle_clean_command, Command("clean"))
    dp.message.register(handle_video)
    dp.startup.register(lambda _: asyncio.create_task(periodic_preview_scan()))
    logger.info("✅ Dispatcher initialized (start/restart ready)")
    make_dispatcher._configured = True  # type: ignore[attr-defined]
    return dp


async def run_polling() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(name)s: %(message)s")
    bot = None
    task_queue: Optional[UserTaskQueue] = None
    try:
        bot = make_bot()
        dp = make_dispatcher()
        import handlers
        print("[INIT] Handlers successfully imported and registered ✅")
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
