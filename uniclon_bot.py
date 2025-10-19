
import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Awaitable, Callable, Dict, List, Optional, Tuple

from dotenv import load_dotenv

from aiogram import Bot, Dispatcher
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
    ) -> None:
        if self._closed:
            raise RuntimeError("Task queue is shutting down")
        async with self._lock:
            queue = self._queues.setdefault(user_id, asyncio.Queue())
            workers = self._workers.setdefault(user_id, [])
            self._task_counter += 1
            task_id = self._task_counter
            self._tasks.setdefault(user_id, []).append(
                TaskInfo(task_id, label, "pending", time.time(), profile=profile)
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
    dp = Dispatcher()
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
