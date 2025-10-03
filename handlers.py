import time
from pathlib import Path
from aiogram import F, Router
from aiogram.types import Message
from aiogram.utils.markdown import hcode
from aiogram.types.input_file import FSInputFile

from uniclon.config import BASE_DIR, OUTPUT_DIR, MAX_COPIES, LOG_TAIL_CHARS, CLEAN_UP_INPUT
from uniclon.utils import parse_copies_from_caption, parse_filename_and_copies
from uniclon.downloader import download_telegram_file
from uniclon.executor import run_script_with_logs, list_new_mp4s

router = Router()


@router.message(F.text == "/start")
async def on_start(message: Message) -> None:
    text = (
        "Привет! Я Uniclon.\n\n"
        "Варианты:\n"
        "• Пришли MP4 как *файл (Document)* с подписью-числом, например: 10.\n"
        "• Если файл большой и не грузится – положи его в папку проекта и пришли текст: \n"
        f"  {hcode('<имя_файла>.mp4 <число>')}.\n\n"
        f"Лимит копий: до {MAX_COPIES}.\n"
        f"Результаты возвращаю из папки ‘{OUTPUT_DIR.name}’."
    )
    await message.answer(text)


# Принимаем видео
@router.message(F.video)
async def handle_video(message: Message, bot) -> None:
    copies = parse_copies_from_caption(message.caption or "")
    if not copies:
        await message.reply(
            f"Укажи количество копий в подписи к видео (1..{MAX_COPIES})."
        )
        return

    ack = await message.reply(f"Сохраняю видео… Копий: {copies}")

    # Download input
    tmp_name = f"input_{message.message_id}.mp4"
    dest_path = BASE_DIR / tmp_name
    try:
        input_path = await download_telegram_file(bot, message, dest_path)
    except Exception as e:
        err = str(e)
        hint = (
            "Файл слишком большой для Telegram Bot API.\n"
            "Скопируй видео в папку проекта и пришли сообщение формата:\n"
            f"{hcode('<имя_файла>.mp4 <число>')} — я запущу скрипт локально."
        ) if ("too big" in err.lower() or "file is too big" in err.lower()) else ""
        await ack.edit_text(f"Ошибка при скачивании файла: {err}\n{hint}")
        return

    await ack.edit_text(f"Файл сохранён: {hcode(input_path.name)}. Запускаю…")
    await _run_and_send(message, ack, input_path, copies)


# Принимаем документ (.mp4)
@router.message(F.document)
async def handle_document(message: Message, bot) -> None:
    copies = parse_copies_from_caption(message.caption or "")
    if not copies:
        await message.reply(
            f"Укажи количество копий в подписи к файлу (1..{MAX_COPIES})."
        )
        return

    ack = await message.reply(f"Сохраняю файл… Копий: {copies}")

    tmp_name = f"input_{message.message_id}.mp4"
    dest_path = BASE_DIR / tmp_name
    try:
        input_path = await download_telegram_file(bot, message, dest_path)
    except Exception as e:
        err = str(e)
        hint = (
            "Файл слишком большой для Telegram Bot API.\n"
            "Скопируй видео в папку проекта и пришли сообщение формата:\n"
            f"{hcode('<имя_файла>.mp4 <число>')} — я запущу скрипт локально."
        ) if ("too big" in err.lower() or "file is too big" in err.lower()) else ""
        await ack.edit_text(f"Ошибка при скачивании файла: {err}\n{hint}")
        return

    await ack.edit_text(f"Файл сохранён: {hcode(input_path.name)}. Запускаю…")
    await _run_and_send(message, ack, input_path, copies)


# Текстовая команда: "<filename>.mp4 <copies>"
@router.message(F.text)
async def handle_text(message: Message) -> None:
    parsed = parse_filename_and_copies(message.text or "")
    if not parsed:
        return
    input_path, copies = parsed
    if not input_path.exists():
        await message.reply(
            f"Файл {hcode(input_path.name)} не найден в {hcode(str(BASE_DIR))}.\n"
            "Скопируй видео в папку проекта или пришли его как файл."
        )
        return

    ack = await message.reply(
        f"Нашёл локальный файл {hcode(input_path.name)}. Копий: {copies}. Запускаю…"
    )
    await _run_and_send(message, ack, input_path, copies)


# Вспомогательная функция общего запуска
async def _run_and_send(message: Message, ack: Message, input_path: Path, copies: int) -> None:
    before = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    start_ts = time.time()

    rc, logs_text = await run_script_with_logs(input_path, copies, BASE_DIR)

    if logs_text.strip():
        tail = logs_text[-LOG_TAIL_CHARS:]
        await message.answer("Логи выполнения (хвост):\n" + hcode(tail))

    if rc != 0:
        await ack.edit_text(
            f"Скрипт завершился с кодом {rc}. Проверь логи и содержимое ‘{OUTPUT_DIR.name}’."
        )
        return

    await ack.edit_text("Готово! Собираю готовые файлы…")

    after = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    new_files = [p for p in after - before]
    if not new_files:
        new_files = await list_new_mp4s(since_ts=start_ts, name_hint=input_path.name)
    if not new_files:
        await ack.edit_text(
            f"Скрипт завершён, но новые .mp4 не найдены в ‘{OUTPUT_DIR.name}’."
        )
        return

    new_files = sorted(new_files)[:copies]

    sent = 0
    for p in new_files:
        try:
            await message.answer_video(video=FSInputFile(p), caption=p.name)
        except Exception:
            await message.answer_document(document=FSInputFile(p), caption=p.name)
        sent += 1

    await ack.edit_text(f"Отправлено файлов: {sent}/{len(new_files)}. ✅")

    if CLEAN_UP_INPUT:
        try:
            if input_path.exists():
                input_path.unlink()
        except Exception:
            pass
