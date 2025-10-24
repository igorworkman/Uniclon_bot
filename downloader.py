
from pathlib import Path

from aiogram import Bot
from aiogram.types import Message


async def download_telegram_file(bot: Bot, message: Message, dest_path: Path) -> Path:
    """Скачивает Video или Document(.mp4) в dest_path, пытается сохранить имя файла."""
    if message.video:
        file_id = message.video.file_id
        original_name = message.video.file_name or dest_path.name
        dest_path = dest_path.with_name(original_name)
    elif message.document:
        fname = (message.document.file_name or "").lower()
        if not fname.endswith(".mp4"):
            raise RuntimeError("Документ не является .mp4")
        file_id = message.document.file_id
        original_name = message.document.file_name or dest_path.name
        dest_path = dest_path.with_name(original_name)
    else:
        raise RuntimeError("Нет видео или .mp4 документа в сообщении")

    tg_file = await bot.get_file(file_id)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        await bot.download(file=tg_file.file_path, destination=dest_path)
    except (AttributeError, TypeError):
        await bot.download_file(tg_file.file_path, destination=dest_path)
    return dest_path
