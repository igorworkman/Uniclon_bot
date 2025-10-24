
from pathlib import Path

import aiohttp
from aiogram import Bot
from aiogram.types import Message


# fix: добавлен HTTPS fallback для скачивания файлов из Telegram
# REGION AI: download_telegram_file fallback
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

    tg_file = await bot.get_file(file_id)
    try:
        await bot.download_file(tg_file.file_path, destination=dest_path)
    except Exception:
        url = f"https://api.telegram.org/file/bot{bot.token}/{tg_file.file_path}"
        async with aiohttp.ClientSession() as session:
            async with session.get(url) as response:
                response.raise_for_status()
                dest_path.write_bytes(await response.read())

    return dest_path
# END REGION AI
