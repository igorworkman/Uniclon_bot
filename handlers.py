import logging
import os
import time
import zipfile
from pathlib import Path
from typing import Dict, Iterable, Optional, Set, Tuple, TYPE_CHECKING
from aiogram import F, Router
from aiogram.filters import Command
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

if TYPE_CHECKING:
    from uniclon_bot import UserTaskQueue


router = Router()
logger = logging.getLogger(__name__)

_task_queue: Optional["UserTaskQueue"] = None
_user_profiles: Dict[int, str] = {}
_user_quality: Dict[int, str] = {}
_user_outputs: Dict[int, Set[Path]] = {}

_TELEGRAM_DOCUMENT_LIMIT = 2 * 1024 * 1024 * 1024  # 2 GB

_VALID_PROFILES = {
    "tiktok": "TikTok",
    "instagram": "Instagram",
    "telegram": "Telegram",
}


def set_task_queue(queue: "UserTaskQueue") -> None:
    global _task_queue
    _task_queue = queue


def _get_task_queue() -> Optional["UserTaskQueue"]:
    return _task_queue


def _get_user_lang(message: Message) -> str:
    if message.from_user and message.from_user.language_code:
        return message.from_user.language_code
    return "ru"


def _get_profile(user_id: int) -> str:
    return _user_profiles.get(user_id, "")


def _set_profile(user_id: int, profile: str) -> None:
    _user_profiles[user_id] = profile


def _get_quality(user_id: int) -> str:
    return _user_quality.get(user_id, "std")


def _set_quality(user_id: int, quality: str) -> None:
    _user_quality[user_id] = quality


def register_user_outputs(user_id: int, files: Iterable[Path]) -> None:
    files = list(files)
    if not files:
        return

    registry = _user_outputs.setdefault(user_id, set())
    for raw_path in files:
        try:
            resolved = raw_path.resolve()
        except FileNotFoundError:
            continue
        registry.add(resolved)


def get_user_output_paths(user_id: int) -> Set[Path]:
    recorded = _user_outputs.get(user_id)
    if not recorded:
        return set()

    existing: Set[Path] = set()
    for item in recorded:
        try:
            if item.exists():
                existing.add(item)
        except OSError:
            continue

    if existing:
        _user_outputs[user_id] = existing
    else:
        _user_outputs.pop(user_id, None)

    return set(existing)


def cleanup_user_outputs(
    user_id: int,
    *,
    keep_newer_than: Optional[float] = None,
    max_mtime: Optional[float] = None,
) -> Tuple[int, int]:
    recorded = list(_user_outputs.get(user_id, set()))
    removed = 0
    skipped = 0

    if not recorded:
        _user_outputs.pop(user_id, None)
        return removed, skipped

    remaining: Set[Path] = set()
    for path in recorded:
        try:
            stat = path.stat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            logger.warning("Failed to stat %s during cleanup: %s", path, exc)
            remaining.add(path)
            continue

        mtime = stat.st_mtime
        should_remove = True
        if keep_newer_than is not None and mtime >= keep_newer_than:
            should_remove = False
        if max_mtime is not None and mtime > max_mtime:
            should_remove = False

        if should_remove:
            try:
                path.unlink()
                removed += 1
            except FileNotFoundError:
                removed += 1
            except OSError as exc:
                logger.warning("Failed to remove %s during cleanup: %s", path, exc)
                remaining.add(path)
                continue
        else:
            remaining.add(path)
            skipped += 1

    if remaining:
        _user_outputs[user_id] = remaining
    else:
        _user_outputs.pop(user_id, None)

    return removed, skipped


def auto_cleanup_stale_outputs(user_id: int, older_than_seconds: int = 3600) -> int:
    threshold = time.time() - older_than_seconds
    removed, _ = cleanup_user_outputs(user_id, max_mtime=threshold)
    return removed


@router.message(Command("profile"))
async def handle_profile(message: Message) -> None:
    if not message.from_user:
        return
    user_id = message.from_user.id
    text = (message.text or "").split(maxsplit=1)
    if len(text) < 2:
        await message.answer("⚠️ Профиль не поддерживается. Доступны: tiktok, instagram, telegram")
        return

    value = text[1].strip().lower()
    if value not in _VALID_PROFILES:
        await message.answer("⚠️ Профиль не поддерживается. Доступны: tiktok, instagram, telegram")
        return

    _set_profile(user_id, value)
    await message.answer(f"✅ Профиль {_VALID_PROFILES[value]} выбран")


@router.message(Command("quality"))
async def handle_quality(message: Message) -> None:
    if not message.from_user:
        return

    user_id = message.from_user.id
    parts = (message.text or "").split(maxsplit=1)
    if len(parts) < 2:
        await message.answer("⚠️ Укажите: /quality high или /quality std")
        return

    value = parts[1].strip().lower()
    if value not in {"high", "std"}:
        await message.answer("⚠️ Укажите: /quality high или /quality std")
        return

    _set_quality(user_id, value)
    label = "High" if value == "high" else "Std"
    await message.answer(f"✅ Качество установлено: {label}")


@router.message(Command("status"))
async def handle_status(message: Message) -> None:
    if not message.from_user:
        return

    queue = _get_task_queue()
    if queue is None:
        await message.answer("💤 У вас нет активных задач")
        return

    tasks = await queue.get_user_tasks(message.from_user.id)
    if not tasks:
        await message.answer("💤 У вас нет активных задач")
        return

    status_labels = {"pending": "⏳ В ожидании", "active": "🔄 Обрабатывается"}
    lines = ["📊 Ваши задачи:"]
    for idx, task in enumerate(tasks, 1):
        status = status_labels.get(task.status, task.status)
        lines.append(f"{idx}. {task.label} — {status}")

    await message.answer("\n".join(lines))


async def _ensure_valid_copies(message: Message, copies, hint_key: str):
    user_id = message.from_user.id if message.from_user else "unknown"
    lang = _get_user_lang(message)
    hint_text = get_text(lang, hint_key)
    if copies is None:
        logger.warning("Copies missing (%s): user=%s msg=%s", hint_key, user_id, message.message_id)
        if hint_key == "hint_video_caption":
            await message.reply("Укажите число копий в подписи к видео")
        else:
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
        if hint_key == "hint_video_caption" and copies > MAX_COPIES:
            await message.reply("Максимум — 20 копий. Уменьшите количество")
        else:
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
    await _enqueue_processing(message, ack, input_path, copies, lang)


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
    await _enqueue_processing(message, ack, input_path, copies, lang)


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
    await _enqueue_processing(message, ack, input_path, copies, lang)


# Вспомогательная функция общего запуска
async def _enqueue_processing(
    message: Message,
    ack: Message,
    input_path: Path,
    copies: int,
    lang: str,
) -> None:
    queue = _get_task_queue()
    user_id = message.from_user.id if message.from_user else 0
    profile = _get_profile(user_id)
    quality = _get_quality(user_id)

    removed_auto = auto_cleanup_stale_outputs(user_id)
    if removed_auto:
        logger.info("Auto-clean removed %s stale files for user=%s", removed_auto, user_id)

    async def task() -> None:
        await _run_and_send(message, ack, input_path, copies, profile, quality)

    if queue is None:
        await task()
        return

    try:
        await queue.enqueue(user_id, task, input_path.name)
    except RuntimeError:
        await task()
        return

    logger.info("Task queued for user=%s", user_id)
    await message.answer("Видео поставлено в очередь. Ожидайте обработки…")


async def _run_and_send(
    message: Message,
    ack: Message,
    input_path: Path,
    copies: int,
    profile: str,
    quality: str,
) -> None:
    before = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    start_ts = time.time()
    lang = _get_user_lang(message)

    await message.answer("Начата обработка видео…")

    try:
        rc, logs_text = await run_script_with_logs(
            input_path,
            copies,
            BASE_DIR,
            profile,
            quality,
        )
    except Exception:
        await message.answer("Произошла ошибка при обработке. Попробуйте ещё раз.")
        raise

    if "⚠️ Обнаружены слишком похожие копии" in logs_text:
        await message.answer("⚠️ Обнаружены слишком похожие копии, выполняется перегенерация…")

    if logs_text.strip():
        tail = logs_text[-LOG_TAIL_CHARS:]
        await message.answer(
            get_text(lang, "logs_tail", logs=hcode(tail))
        )

    if rc != 0:
        logger.error(
            "Script failed with code %s for %s (copies=%s, profile=%s)",
            rc,
            input_path,
            copies,
            profile,
        )
        error_text = get_text(
            lang,
            "script_failed",
            rc=rc,
            output_dir=OUTPUT_DIR.name,
        )
        await message.answer("Произошла ошибка при обработке. Попробуйте ещё раз.")
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
        await message.answer("Произошла ошибка при обработке. Попробуйте ещё раз.")
        return

    new_files = sorted(new_files)[:copies]

    if message.from_user:
        register_user_outputs(message.from_user.id, new_files)

    await message.answer("Готово! Отправляю уникализированные копии…")

    sent = 0
    archive_path: Optional[Path] = None
    archive_sent = False

    if len(new_files) > 10:
        total_size = 0
        total_known = True
        for file_path in new_files:
            try:
                total_size += file_path.stat().st_size
            except OSError as exc:
                total_known = False
                logger.warning("Failed to read size of %s for archive estimation: %s", file_path, exc)
            if total_size > _TELEGRAM_DOCUMENT_LIMIT:
                break

        if total_size <= _TELEGRAM_DOCUMENT_LIMIT:
            archive_name = f"uniclon_{int(time.time())}_{message.message_id or 'zip'}"
            archive_path = OUTPUT_DIR / f"{archive_name}.zip"
            try:
                with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                    for file_path in new_files:
                        try:
                            archive.write(file_path, arcname=file_path.name)
                        except OSError as exc:
                            logger.exception("Failed to add %s to archive: %s", file_path, exc)
                            raise
            except Exception:
                logger.exception("Failed to build archive %s", archive_path)
            else:
                try:
                    await message.answer_document(
                        document=FSInputFile(archive_path),
                        caption="📦 Ваши уникализированные видео в архиве (10+ файлов)",
                    )
                except Exception:
                    logger.exception("Failed to send archive %s", archive_path)
                else:
                    archive_sent = True
                    sent = len(new_files)

        if not archive_sent and total_size > _TELEGRAM_DOCUMENT_LIMIT and total_known:
            logger.info(
                "Total size %s of %s files exceeds Telegram limit; falling back to per-file sending",
                total_size,
                len(new_files),
            )

    if not archive_sent:
        for p in new_files:
            try:
                await message.answer_video(video=FSInputFile(p), caption=p.name)
            except Exception:
                logger.exception("Failed to send video %s; fallback to document", p)
                await message.answer_document(document=FSInputFile(p), caption=p.name)
            sent += 1

    if archive_path and archive_path.exists():
        try:
            archive_path.unlink()
        except OSError as exc:
            logger.warning("Failed to remove temporary archive %s: %s", archive_path, exc)

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
