
import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer
from aiogram.exceptions import TelegramAPIError
from aiohttp import ClientError

from uniclon.config import BOT_TOKEN, BOT_API_BASE
from uniclon.handlers import router


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
    try:
        bot = make_bot()
        dp = make_dispatcher()
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    except (TelegramAPIError, ClientError, ValueError) as exc:
        logging.exception("Failed to start polling due to invalid token or API configuration: %s", exc)
        raise
    finally:
        if bot and bot.session:
            await bot.session.close()


if __name__ == "__main__":
    try:
        asyncio.run(run_polling())
    except (KeyboardInterrupt, SystemExit):
        logging.info("Bot shutdown requested. Exiting gracefully.")
