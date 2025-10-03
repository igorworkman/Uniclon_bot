import logging
import os
import time
from pathlib import Path
from aiogram import F, Router
from aiogram.types import Message
from aiogram.utils.markdown import hcode
from aiogram.types.input_file import FSInputFile

# REGION AI: imports
from config import BASE_DIR, OUTPUT_DIR, MAX_COPIES, LOG_TAIL_CHARS, CLEAN_UP_INPUT
from utils import parse_copies_from_caption, parse_filename_and_copies
from downloader import download_telegram_file
from executor import run_script_with_logs, list_new_mp4s
# END REGION AI
from locales import get_text

router = Router()
logger = logging.getLogger(__name__)


def _get_user_lang(message: Message) -> str:
    if message.from_user and message.from_user.language_code:
        return message.from_user.language_code
    return "ru"


async def _ensure_valid_copies(message: Message, copies, hint_key: str):
    user_id = message.from_user.id if message.from_user else "unknown"
    lang = _get_user_lang(message)
    hint_text = get_text(lang, hint_key)
    if copies is None:
        logger.warning("Copies missing (%s): user=%s msg=%s", hint_key, user_id, message.message_id)
        await message.reply(
            get_text(lang, "copies_missing", hint=hint_text, max_copies=MAX_COPIES)
        )
        return None
    if copies < 1 or copies > MAX_COPIES:
        logger.warning(
            "Copies out of range (%s): %s. user=%s msg=%s",
            hint_key,
            copies,
            user_id,
            message.message_id,
        )
        await message.reply(
            get_text(lang, "copies_out_of_range", max_copies=MAX_COPIES)
        )
        return None
    return copies


@router.message(F.text == "/start")
async def on_start(message: Message) -> None:
    lang = _get_user_lang(message)
    code_example = hcode(get_text(lang, "code_example"))
    text = get_text(
        lang,
        "start_text",
        code_example=code_example,
        max_copies=MAX_COPIES,
        output_dir=OUTPUT_DIR.name,
    )
    await message.answer(text)


# Принимаем видео
@router.message(F.video)
async def handle_video(message: Message, bot) -> None:
    lang = _get_user_lang(message)
    copies = parse_copies_from_caption(message.caption or "")
    copies = await _ensure_valid_copies(message, copies, "hint_video_caption")
    if copies is None:
        return

    ack = await message.reply(get_text(lang, "saving_video", copies=copies))

    # Download input
    tmp_name = f"input_{message.message_id}.mp4"
    dest_path = BASE_DIR / tmp_name
    try:
        input_path = await download_telegram_file(bot, message, dest_path)
    except Exception as e:
        user_id = message.from_user.id if message.from_user else "unknown"
        logger.exception("Failed to download video: user=%s msg=%s", user_id, message.message_id)
        err = str(e)
        hint = ""
        if "too big" in err.lower() or "file is too big" in err.lower():
            hint = get_text(
                lang,
                "download_too_big_hint",
                code_example=hcode(get_text(lang, "code_example")),
            )
        error_text = get_text(lang, "download_error", error=err)
        if hint:
            error_text = f"{error_text}\n{hint}"
        await ack.edit_text(error_text)
        return

    await ack.edit_text(
        get_text(lang, "file_saved", filename=hcode(input_path.name))
    )
    await _run_and_send(message, ack, input_path, copies)


# Принимаем документ (.mp4)
@router.message(F.document)
async def handle_document(message: Message, bot) -> None:
    lang = _get_user_lang(message)
    copies = parse_copies_from_caption(message.caption or "")
    copies = await _ensure_valid_copies(message, copies, "hint_document_caption")
    if copies is None:
        return

    ack = await message.reply(get_text(lang, "saving_document", copies=copies))

    tmp_name = f"input_{message.message_id}.mp4"
    dest_path = BASE_DIR / tmp_name
    try:
        input_path = await download_telegram_file(bot, message, dest_path)
    except Exception as e:
        user_id = message.from_user.id if message.from_user else "unknown"
        logger.exception("Failed to download document: user=%s msg=%s", user_id, message.message_id)
        err = str(e)
        hint = ""
        if "too big" in err.lower() or "file is too big" in err.lower():
            hint = get_text(
                lang,
                "download_too_big_hint",
                code_example=hcode(get_text(lang, "code_example")),
            )
        error_text = get_text(lang, "download_error", error=err)
        if hint:
            error_text = f"{error_text}\n{hint}"
        await ack.edit_text(error_text)
        return

    await ack.edit_text(
        get_text(lang, "file_saved", filename=hcode(input_path.name))
    )
    await _run_and_send(message, ack, input_path, copies)


# Текстовая команда: "<filename>.mp4 <copies>"
@router.message(F.text)
async def handle_text(message: Message) -> None:
    lang = _get_user_lang(message)
    parsed = parse_filename_and_copies(message.text or "")
    if not parsed:
        return
    input_path, copies = parsed
    copies = await _ensure_valid_copies(message, copies, "hint_message")
    if copies is None:
        return
    if not input_path.exists():
        user_id = message.from_user.id if message.from_user else "unknown"
        logger.warning("Local file not found: %s. user=%s msg=%s", input_path, user_id, message.message_id)
        await message.reply(
            get_text(
                lang,
                "file_not_found",
                filename=hcode(input_path.name),
                base_dir=hcode(str(BASE_DIR)),
            )
        )
        return

    ack = await message.reply(
        get_text(
            lang,
            "local_file_found",
            filename=hcode(input_path.name),
            copies=copies,
        )
    )
    await _run_and_send(message, ack, input_path, copies)


# Вспомогательная функция общего запуска
async def _run_and_send(message: Message, ack: Message, input_path: Path, copies: int) -> None:
    before = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    start_ts = time.time()
    lang = _get_user_lang(message)

    rc, logs_text = await run_script_with_logs(input_path, copies, BASE_DIR)

    if logs_text.strip():
        tail = logs_text[-LOG_TAIL_CHARS:]
        await message.answer(
            get_text(lang, "logs_tail", logs=hcode(tail))
        )

    if rc != 0:
        logger.error("Script failed with code %s for %s (copies=%s)", rc, input_path, copies)
        error_text = get_text(
            lang,
            "script_failed",
            rc=rc,
            output_dir=OUTPUT_DIR.name,
        )
        await ack.edit_text(error_text)
        await message.answer(error_text)
        return

    await ack.edit_text(get_text(lang, "collecting_files"))

    after = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    new_files = [p for p in after - before]
    if not new_files:
        new_files = await list_new_mp4s(since_ts=start_ts, name_hint=input_path.name)
    if not new_files:
        logger.error("Script succeeded but produced no files for %s (copies=%s)", input_path, copies)
        await ack.edit_text(
            get_text(lang, "no_new_files", output_dir=OUTPUT_DIR.name)
        )
        return

    new_files = sorted(new_files)[:copies]

    sent = 0
    for p in new_files:
        try:
            await message.answer_video(video=FSInputFile(p), caption=p.name)
        except Exception:
            logger.exception("Failed to send video %s; fallback to document", p)
            await message.answer_document(document=FSInputFile(p), caption=p.name)
        sent += 1

    await ack.edit_text(
        get_text(lang, "files_sent_summary", sent=sent, total=len(new_files))
    )

    if CLEAN_UP_INPUT:
        try:
            os.remove(input_path)
        except FileNotFoundError:
            pass
        except Exception:
            logger.exception("Failed to remove input file %s", input_path)
        else:
            logger.info("Temporary file %s deleted.", input_path)
