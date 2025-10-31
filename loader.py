from __future__ import annotations

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer
from aiogram.fsm.storage.memory import MemoryStorage

from config import BOT_API_BASE, BOT_TOKEN


def _make_bot() -> Bot:
    if BOT_API_BASE:
        session = AiohttpSession(api=TelegramAPIServer.from_base(BOT_API_BASE))
        return Bot(
            BOT_TOKEN,
            default=DefaultBotProperties(parse_mode="HTML"),
            session=session,
        )
    return Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"))


bot: Bot = _make_bot()
dp: Dispatcher = Dispatcher(storage=MemoryStorage())

__all__ = ("bot", "dp")
