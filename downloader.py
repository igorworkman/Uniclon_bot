
import asyncio
from pathlib import Path

import aiohttp
from aiogram import Bot
from aiogram.exceptions import TelegramBadRequest
from aiogram.types import Message


async def download_telegram_file(bot: Bot, message: Message, dest_path: Path) -> Path:
    """Скачивает Video или Document(.mp4) в dest_path, пытается сохранить имя файла."""
    if message.video:
        file_id = message.video.file_id
        original_name = message.video.file_name or dest_path.name
    elif message.document:
        fname = (message.document.file_name or "").lower()
        if not fname.endswith(".mp4"):
            raise RuntimeError("Документ не является .mp4")
        file_id = message.document.file_id
        original_name = message.document.file_name or dest_path.name
    else:
        raise RuntimeError("Нет видео или .mp4 документа в сообщении")

    dest_path = dest_path.with_name(original_name)
    dest_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        tg_file = await bot.get_file(file_id)
        await bot.download_file(tg_file.file_path, destination=dest_path)
        return dest_path
    except TelegramBadRequest as error:
        error_text = str(error).lower()
        if "wrong file_id" not in error_text and "temporarily unavailable" not in error_text:
            raise

    await asyncio.sleep(1)
    tg_file = await bot.get_file(file_id)
    file_url = f"https://api.telegram.org/file/bot{bot.token}/{tg_file.file_path}"
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(file_url) as resp:
                if resp.status != 200:
                    raise RuntimeError("Telegram CDN не отдаёт файл. Попробуйте позже.")
                dest_path.write_bytes(await resp.read())
    except aiohttp.ClientError as error:
        raise RuntimeError("Telegram CDN не отдаёт файл. Попробуйте позже.") from error

    return dest_path
