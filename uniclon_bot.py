
import asyncio
import logging
from typing import Awaitable, Callable, Dict, List, Optional

from dotenv import load_dotenv

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer
from aiogram.exceptions import TelegramAPIError
from aiohttp import ClientError

load_dotenv()

# REGION AI: local imports
from config import BOT_TOKEN, BOT_API_BASE
from handlers import router, set_task_queue
# END REGION AI


class UserTaskQueue:
    def __init__(self, per_user_limit: int = 1) -> None:
        self._per_user_limit = max(1, per_user_limit)
        self._queues: Dict[int, asyncio.Queue[Optional[Callable[[], Awaitable[None]]]]] = {}
        self._workers: Dict[int, List[asyncio.Task[None]]] = {}
        self._lock = asyncio.Lock()
        self._closed = False
        self._idle_timeout = 5.0

    async def enqueue(self, user_id: int, task_factory: Callable[[], Awaitable[None]]) -> None:
        if self._closed:
            raise RuntimeError("Task queue is shutting down")
        async with self._lock:
            queue = self._queues.setdefault(user_id, asyncio.Queue())
            workers = self._workers.setdefault(user_id, [])
            if workers:
                alive_workers: List[asyncio.Task[None]] = []
                for worker in workers:
                    if not worker.done():
                        alive_workers.append(worker)
                if len(alive_workers) != len(workers):
                    self._workers[user_id] = workers = alive_workers
            await queue.put(task_factory)
            while len(workers) < self._per_user_limit:
                workers.append(asyncio.create_task(self._worker(user_id, queue)))

    async def close(self) -> None:
        self._closed = True
        async with self._lock:
            snapshot = [
                (uid, self._queues[uid], list(self._workers.get(uid, []))) for uid in list(self._queues)
            ]
        for _, queue, workers in snapshot:
            for _ in workers:
                await queue.put(None)
        tasks = [task for _, _, workers in snapshot for task in workers]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _worker(self, user_id: int, queue: asyncio.Queue[Optional[Callable[[], Awaitable[None]]]]) -> None:
        unregistered = False
        try:
            while True:
                try:
                    task_factory = await asyncio.wait_for(queue.get(), timeout=self._idle_timeout)
                except asyncio.TimeoutError:
                    async with self._lock:
                        if queue.empty():
                            self._unregister_worker_locked(user_id, queue)
                            unregistered = True
                            break
                    continue
                if task_factory is None:
                    queue.task_done()
                    break
                try:
                    await task_factory()
                except Exception:  # noqa: BLE001
                    logging.exception("Queued task for user %s failed", user_id)
                finally:
                    queue.task_done()
        finally:
            if not unregistered:
                async with self._lock:
                    self._unregister_worker_locked(user_id, queue)

    def _unregister_worker_locked(
        self,
        user_id: int,
        queue: asyncio.Queue[Optional[Callable[[], Awaitable[None]]]],
    ) -> None:
        workers = self._workers.get(user_id, [])
        current = asyncio.current_task()
        if current in workers:
            workers.remove(current)
        if not workers:
            self._workers.pop(user_id, None)
            if queue.empty():
                self._queues.pop(user_id, None)


def make_bot() -> Bot:
    if BOT_API_BASE:
        session = AiohttpSession(api=TelegramAPIServer.from_base(BOT_API_BASE))
        return Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"), session=session)
    return Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"))


def make_dispatcher() -> Dispatcher:
    dp = Dispatcher()
    dp.include_router(router)
    return dp


async def run_polling() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(name)s: %(message)s")
    bot = None
    task_queue: Optional[UserTaskQueue] = None
    try:
        bot = make_bot()
        dp = make_dispatcher()
        task_queue = UserTaskQueue()
        set_task_queue(task_queue)
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    except (TelegramAPIError, ClientError, ValueError) as exc:
        logging.exception("Failed to start polling due to invalid token or API configuration: %s", exc)
        raise
    finally:
        if bot and bot.session:
            await bot.session.close()
        if task_queue:
            await task_queue.close()


if __name__ == "__main__":
    try:
        asyncio.run(run_polling())
    except (KeyboardInterrupt, SystemExit):
        logging.info("Bot shutdown requested. Exiting gracefully.")
