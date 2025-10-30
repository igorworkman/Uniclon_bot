import asyncio
import logging
import os
import re
import shutil
import time
import zipfile
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple, TYPE_CHECKING

import psutil
from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.types import CallbackQuery, Message
from aiogram.types import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    KeyboardButton,
    ReplyKeyboardMarkup,
)
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.utils.markdown import hcode
from aiogram.types.input_file import FSInputFile

# REGION AI: imports
from config import (
    BASE_DIR,
    OUTPUT_DIR,
    MAX_COPIES,
    LOG_TAIL_CHARS,
    CLEAN_UP_INPUT,
    CHECKS_DIR,
    FORCE_ZIP_ARCHIVE,
)
from utils import (
    parse_copies_from_caption,
    parse_filename_and_copies,
    perform_self_audit,
    cleanup_user_outputs,
)
from downloader import download_telegram_file
from executor import (
    run_script_with_logs,
    list_new_mp4s,
    probe_video_duration,
    process_copies_sequentially,
)
# END REGION AI
from locales import get_text

if TYPE_CHECKING:
    from uniclon_bot import UserTaskQueue


router = Router()
logger = logging.getLogger(__name__)


@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    _cleanup_restart_data()
    await message.answer(
        "👋 Привет, я **Uniclon v1.8** — бот для уникализации видео.\n\n"
        "🎥 Отправь мне MP4 и в подписи укажи количество копий (1–5).\n"
        "Каждая копия придёт отдельно, по мере готовности.\n\n"
        "Если хочешь сбросить всё — нажми 🔄 **RESTART**.",
        reply_markup=ReplyKeyboardMarkup(
            keyboard=[[KeyboardButton(text="🔄 RESTART")]],
            resize_keyboard=True,
        ),
        parse_mode="Markdown",
    )
    await state.set_state(VideoUpload.waiting_for_video)


def _cleanup_restart_data() -> None:
    temp_dir = BASE_DIR / "temp"
    state_file = BASE_DIR / "state.json"

    if temp_dir.exists():
        try:
            shutil.rmtree(temp_dir)
        except Exception:
            logger.exception("Failed to remove temporary directory %s", temp_dir)

    if state_file.exists():
        try:
            state_file.unlink()
        except Exception:
            logger.exception("Failed to remove state file %s", state_file)


@router.message(F.text == "🔄 RESTART")
async def restart_bot(message: Message, state: FSMContext) -> None:
    await state.clear()
    _cleanup_restart_data()
    await state.set_state(VideoUpload.waiting_for_video)
    await message.answer("♻️ Всё очищено. Готов к новой обработке!")


async def finalize_video(message: Message, output_path: Path) -> None:
    """Send processed video with a document fallback."""

    caption = output_path.name
    try:
        await message.answer_video(video=FSInputFile(output_path), caption=caption)
    except Exception:
        logger.exception("Failed to send video %s; fallback to document", output_path)
        await message.answer_document(document=FSInputFile(output_path), caption=caption)

_task_queue: Optional["UserTaskQueue"] = None
_user_profiles: Dict[int, str] = {}
_user_quality: Dict[int, str] = {}
_user_outputs: Dict[int, Set[Path]] = {}
_user_default_copies: Dict[int, int] = {}

_TELEGRAM_DOCUMENT_LIMIT = 2 * 1024 * 1024 * 1024  # 2 GB

# REGION AI: available export profiles
_VALID_PROFILES = {
    "tiktok": "TikTok",
    "instagram": "Instagram",
    "youtube": "YouTube Shorts",
}
# END REGION AI


class FSM(StatesGroup):
    awaiting_copies = State()
    awaiting_profile = State()
    awaiting_preview = State()

class VideoUpload(StatesGroup): waiting_for_video = State()
class ProfileChoice(StatesGroup): profile = State()
class CoverChoice(StatesGroup): decision = State()


# REGION AI: dynamic profile keyboard
def _profile_keyboard() -> InlineKeyboardMarkup:
    first_row = [
        InlineKeyboardButton(
            text=_VALID_PROFILES["tiktok"], callback_data="profile:tiktok"
        ),
        InlineKeyboardButton(
            text=_VALID_PROFILES["instagram"], callback_data="profile:instagram"
        ),
    ]
    second_row = [
        InlineKeyboardButton(
            text=_VALID_PROFILES["youtube"], callback_data="profile:youtube"
        )
    ]
    return InlineKeyboardMarkup(inline_keyboard=[first_row, second_row])
# END REGION AI


def _preview_keyboard() -> InlineKeyboardMarkup:
    buttons = [
        InlineKeyboardButton(text="Да", callback_data="preview:yes"),
        InlineKeyboardButton(text="Нет", callback_data="preview:no"),
    ]
    return InlineKeyboardMarkup(inline_keyboard=[buttons])


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


def _cleanup_user_outputs_impl(
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
        await message.answer(
            "⚠️ Профиль не поддерживается. Доступны: tiktok, instagram, youtube"
        )
        return

    value = text[1].strip().lower()
    if value not in _VALID_PROFILES:
        await message.answer(
            "⚠️ Профиль не поддерживается. Доступны: tiktok, instagram, youtube"
        )
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


@router.message(Command("cancel"))
async def handle_cancel(message: Message, state: FSMContext) -> None:
    current = await state.get_state()
    if not current:
        await message.answer("Нет активного диалога.")
        return
    await state.clear()
    await message.answer("Диалог отменён.")


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
        profile_label = ""
        if getattr(task, "profile", None):
            human = _VALID_PROFILES.get(task.profile or "", task.profile)
            profile_label = f" [{human}]"
        lines.append(f"{idx}. {task.label}{profile_label} — {status}")

    await message.answer("\n".join(lines))


@router.message(Command("go"))
async def handle_go_command(message: Message) -> None:
    if not message.from_user:
        return
    parts = (message.text or "").split(maxsplit=1)
    if len(parts) < 2:
        await message.reply("Не указано количество копий (1–20)")
        return
    try:
        raw_copies = int(parts[1])
    except ValueError:
        await message.reply("Не указано количество копий (1–20)")
        return
    copies = await _ensure_valid_copies(
        message,
        raw_copies,
        "hint_message",
        allow_fallback=False,
    )
    if copies is None:
        return
    user_id = message.from_user.id
    logger.info("/go command: user=%s copies=%s", user_id, copies)
    lang = _get_user_lang(message)
    if lang.startswith("ru"):
        text = f"Количество копий установлено: {copies}"
    else:
        text = f"Copies count set to {copies}"
    await message.reply(text)


async def _ensure_valid_copies(
    message: Message,
    copies,
    hint_key: str,
    *,
    allow_fallback: bool = True,
):
    user = message.from_user
    user_id = user.id if user else None
    lang = _get_user_lang(message)
    if copies is None and allow_fallback:
        if user_id is not None:
            copies = _user_default_copies.get(user_id, 3)
        else:
            copies = 3
    if copies is None:
        logger.warning(
            "Copies missing (%s): user=%s msg=%s",
            hint_key,
            user_id or "unknown",
            message.message_id,
        )
        await message.reply(
            "Не указано количество копий (1–20)"
            if lang.startswith("ru")
            else get_text(lang, "copies_missing", max_copies=MAX_COPIES)
        )
        return None
    if copies < 1:
        logger.warning(
            "Copies below minimum (%s): %s. user=%s msg=%s",
            hint_key,
            copies,
            user_id or "unknown",
            message.message_id,
        )
        await message.reply(
            "Не указано количество копий (1–20)"
            if lang.startswith("ru")
            else get_text(lang, "copies_missing", max_copies=MAX_COPIES)
        )
        return None
    if copies > MAX_COPIES:
        logger.warning(
            "Copies out of range (%s): %s. user=%s msg=%s",
            hint_key,
            copies,
            user_id or "unknown",
            message.message_id,
        )
        await message.reply(
            "Максимум можно создать 20 копий"
            if lang.startswith("ru")
            else get_text(lang, "copies_out_of_range", max_copies=MAX_COPIES)
        )
        return None
    if user_id is not None:
        _user_default_copies[user_id] = copies
    return copies


# Принимаем видео


async def _process_video_submission(
    message: Message,
    bot: Bot,
    copies: int,
    lang: str,
    *,
    profile_override: Optional[str] = None,
    save_preview: bool = True,
    state: Optional[FSMContext] = None,
) -> None:
    if not (message.video or getattr(message.document, "mime_type", "") == "video/mp4"):
        await message.answer("❌ Похоже, ты не отправил видеофайл (.mp4). Попробуй ещё раз."); return

    if state is not None and profile_override is None:
        await message.answer(
            "Теперь выбери профиль платформы:\nВыберите профиль платформы:",
            reply_markup=_profile_keyboard(),
        )
        await state.set_state(ProfileChoice.profile)
        return

    ack = await message.reply(get_text(lang, "saving_video", copies=copies))

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
    await _enqueue_processing(
        message,
        ack,
        input_path,
        copies,
        lang,
        profile_override=profile_override,
        save_preview=save_preview,
    )


@router.message(F.video)
async def handle_video(message: Message, bot: Bot, state: FSMContext) -> None:
    lang = _get_user_lang(message)
    copies = parse_copies_from_caption(message.caption or "")
    copies = await _ensure_valid_copies(message, copies, "hint_video_caption")
    if copies is None:
        await state.clear()
        await state.set_state(FSM.awaiting_copies)
        await state.update_data(message=message)
        await message.answer(
            f"Сколько копий вам нужно создать? Введите число от 1 до {MAX_COPIES}."
        )
        return

    await state.clear(); await state.update_data(message=message, copies=copies); await _process_video_submission(message, bot, copies, lang, state=state)


@router.message(FSM.awaiting_copies)
async def handle_copies_input(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    original_message: Optional[Message] = data.get("message")
    if (
        not original_message
        or not message.from_user
        or not original_message.from_user
        or message.from_user.id != original_message.from_user.id
    ):
        await message.answer("Сессия не найдена. Отправьте видео ещё раз.")
        await state.clear()
        return

    text = (message.text or "").strip()
    try:
        copies = int(text)
    except ValueError:
        await message.answer(f"Введите число от 1 до {MAX_COPIES}.")
        return

    if copies < 1 or copies > MAX_COPIES:
        await message.answer(f"Введите число от 1 до {MAX_COPIES}.")
        return

    await state.update_data(copies=copies); lang = _get_user_lang(original_message)
    await _process_video_submission(original_message, message.bot, copies, lang, state=state)


@router.callback_query(ProfileChoice.profile)
async def handle_profile_choice(callback: CallbackQuery, state: FSMContext) -> None:
    data = callback.data or ""
    if not data.startswith("profile:"):
        await callback.answer("Некорректный выбор", show_alert=True)
        return

    profile = data.split(":", 1)[1]
    if profile not in {"tiktok", "instagram", "youtube"}:
        await callback.answer("Профиль недоступен", show_alert=True)
        return

    stored = await state.get_data()
    original_message: Optional[Message] = stored.get("message")
    copies = stored.get("copies")

    if (
        not original_message
        or copies is None
        or not callback.from_user
        or not original_message.from_user
        or callback.from_user.id != original_message.from_user.id
    ):
        await state.clear()
        await callback.answer("Сессия устарела", show_alert=True)
        return

    await state.update_data(profile=profile)
    if callback.message:
        try:
            await callback.message.edit_reply_markup()
        except Exception:
            pass

    await callback.answer(f"{_VALID_PROFILES.get(profile, profile)} выбрано")
    prompt_target = callback.message or original_message
    if prompt_target:
        await prompt_target.answer(
            "Сохранять PNG-обложки из видео?", reply_markup=_preview_keyboard()
        )
    await state.set_state(CoverChoice.decision)


@router.callback_query(CoverChoice.decision)
async def handle_preview_choice(callback: CallbackQuery, state: FSMContext) -> None:
    data = callback.data or ""
    if not data.startswith("preview:"):
        await callback.answer("Некорректный выбор", show_alert=True)
        return

    choice = data.split(":", 1)[1]
    if choice not in {"yes", "no"}:
        await callback.answer("Некорректный выбор", show_alert=True)
        return

    stored = await state.get_data()
    original_message: Optional[Message] = stored.get("message")
    copies = stored.get("copies")
    profile = stored.get("profile")

    if (
        not original_message
        or copies is None
        or profile not in {"tiktok", "instagram", "youtube"}
        or not callback.from_user
        or not original_message.from_user
        or callback.from_user.id != original_message.from_user.id
    ):
        await state.clear()
        await callback.answer("Сессия устарела", show_alert=True)
        return

    await state.clear()
    if callback.message:
        try:
            await callback.message.edit_reply_markup()
        except Exception:
            pass

    save_preview = choice == "yes"
    await callback.answer(
        "PNG-обложки будут сохранены" if save_preview else "PNG-обложки сохранены не будут"
    )

    lang = _get_user_lang(original_message)
    bot = callback.bot
    await _process_video_submission(
        original_message,
        bot,
        copies,
        lang,
        profile_override=profile,
        save_preview=save_preview,
    )


# Принимаем документ (.mp4)
@router.message(F.document)
async def handle_document(message: Message, bot: Bot) -> None:
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
    *,
    profile_override: Optional[str] = None,
    save_preview: bool = True,
) -> None:
    queue = _get_task_queue()
    user_id = message.from_user.id if message.from_user else 0
    profile = profile_override if profile_override is not None else _get_profile(user_id)
    quality = _get_quality(user_id)

    # REGION AI: enqueue logging
    logger.info(
        "🚀 Старт задачи: user=%s | video=%s | copies=%s | profile=%s | q=%s | preview=%s",
        user_id,
        input_path.name,
        copies,
        profile or "-",
        quality,
        "yes" if save_preview else "no",
    )
    # END REGION AI

    if copies > 5:
        copies = 5
        await message.answer("⚠️ Максимум 5 копий за один запуск.")

    removed_auto = auto_cleanup_stale_outputs(user_id)
    if removed_auto:
        logger.info("Auto-clean removed %s stale files for user=%s", removed_auto, user_id)

    async def task() -> None:
        await _run_and_send(
            message,
            ack,
            input_path,
            copies,
            profile,
            quality,
            save_preview,
        )

    # REGION AI: linear execution
    await task()
    return
    # END REGION AI

    if queue is None:
        await task()
        return

    try:
        await queue.enqueue(
            user_id,
            task,
            input_path.name,
            profile=profile or None,
            copies=copies,
            save_preview=save_preview,
            quality=quality,
        )
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
    save_preview: bool,
) -> None:
    logger.info(f"Starting process for {copies} copies of {input_path.name}")
    before = {p.resolve() for p in OUTPUT_DIR.glob('*.mp4')}
    start_ts = time.time()
    lang = _get_user_lang(message)
    preview_dir = OUTPUT_DIR / "previews"

    if profile and profile.lower() == "tiktok":
        try:
            duration_val = await probe_video_duration(input_path)
        except Exception:  # noqa: BLE001
            logger.exception("Failed to probe duration for %s", input_path)
            duration_val = None
        if duration_val and duration_val > 60.0:
            await message.answer("Видео превышает 60 с, будет укорочено.")

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

    temporary_error = rc != 0 and (
        "RETRY" in logs_text or "UniqScore=0.0" in logs_text
    )
    sequential_delivery = False
    delivered_files: List[Path] = []
    if temporary_error:
        logger.warning(
            "Temporary failure detected for %s; invoking safe retry", input_path.name
        )
        await message.answer("⚠️ Обнаружена временная ошибка, запускаем защитный режим…")
        sequential_delivery = True
        deliveries = await process_copies_sequentially(
            input_path,
            copies,
            profile,
            quality,
        )
        success_count = 0
        for item in deliveries:
            idx = item["index"]
            path = item.get("path")
            if path and path.exists():
                delivered_files.append(path)
                success_count += 1
                await finalize_video(message, path)
                logger.info(
                    "[Copy %s/%s] Done | CPU=%s%% | %s",
                    idx,
                    copies,
                    psutil.cpu_percent(),
                    path,
                )
                await message.answer(f"✅ Копия {idx}/{copies} готова!")
                continue
            if item.get("error") == "timeout":
                await message.answer(
                    f"⚠️ Копия #{idx} не успела сгенерироваться за 5 минут — пропущена."
                )
            else:
                await message.answer(
                    f"⚠️ Ошибка при создании копии #{idx}: {item.get('error', 'unknown')}"
                )
        failed_count = copies - success_count
        rc = 0 if failed_count == 0 else rc
        temp_errors = failed_count
        progress_text = (
            f"✅ Успешно: {success_count}/{copies}\n"
            f"⚠️ Временные ошибки: {temp_errors}"
        )
        try:
            await ack.edit_text(progress_text)
        except Exception:
            pass
        await message.answer(progress_text)

    if "⚠️ Обнаружены слишком похожие копии" in logs_text:
        await message.answer("⚠️ Обнаружены слишком похожие копии, выполняется перегенерация…")

    if logs_text.strip():
        tail = logs_text[-LOG_TAIL_CHARS:]
        await message.answer(
            get_text(lang, "logs_tail", logs=hcode(tail))
        )

    if rc != 0:
        if sequential_delivery and delivered_files:
            logger.warning(
                "Protective sequential mode partially failed for %s (delivered=%s/%s)",
                input_path,
                len(delivered_files),
                copies,
            )
            rc = 0
        else:
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
    if sequential_delivery and delivered_files:
        new_files = delivered_files

    preview_files: List[Path] = []
    if save_preview:
        preview_roots: List[Path] = [preview_dir, CHECKS_DIR / "previews"]
        seen_previews: Set[Path] = set()
        for file_path in new_files:
            stem = file_path.stem
            for root in preview_roots:
                if not root.exists():
                    continue
                candidate = root / f"{stem}.png"
                for extra in (candidate, *root.glob(f"{stem}_final_v*.png")):
                    if extra.exists() and extra not in seen_previews:
                        seen_previews.add(extra)
                        preview_files.append(extra)
    else:
        removed_previews = 0
        user_id = message.from_user.id if message.from_user else 0
        for file_path in new_files:
            preview_path = preview_dir / f"{file_path.stem}.png"
            if preview_path.exists():
                try:
                    preview_path.unlink()
                    removed_previews += 1
                except OSError as exc:
                    logger.warning(
                        "Failed to remove preview %s for %s: %s",
                        preview_path,
                        file_path,
                        exc,
                    )
        if removed_previews:
            logger.info(
                "Removed %s preview files for user=%s", removed_previews, user_id
            )

    if message.from_user:
        register_user_outputs(message.from_user.id, new_files)

    await message.answer(
        "Готово! Отправляю уникализированные копии…\n🛡 Метаданные и контейнер обновлены."
    )

    sent = 0
    archive_path: Optional[Path] = None
    archive_sent = False
    preview_archive_path: Optional[Path] = None
    if sequential_delivery:
        sent = len(delivered_files)
        archive_sent = True

    should_zip = len(new_files) > 10 or FORCE_ZIP_ARCHIVE
    if should_zip and not sequential_delivery:
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

        manifest_path = OUTPUT_DIR / "manifest.csv"
        report_path = CHECKS_DIR / "uniclon_report.csv"
        extra_files: List[Path] = []
        if manifest_path.exists():
            extra_files.append(manifest_path)
        if report_path.exists():
            extra_files.append(report_path)

        for extra in extra_files:
            try:
                total_size += extra.stat().st_size
            except OSError:
                continue

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
                    for extra in extra_files:
                        try:
                            archive.write(extra, arcname=extra.name)
                        except OSError as exc:
                            logger.warning("Failed to add %s to archive: %s", extra, exc)
            except Exception:
                logger.exception("Failed to build archive %s", archive_path)
            else:
                try:
                    await message.answer_document(
                        document=FSInputFile(archive_path),
                        caption="📦 Архив с уникализированными видео + manifest.csv + uniclon_report.csv",
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
            await finalize_video(message, p)
            sent += 1

    if save_preview and preview_files:
        if len(preview_files) > 10:
            archive_name = f"previews_{int(time.time())}_{message.message_id or 'zip'}"
            preview_archive_path = OUTPUT_DIR / f"{archive_name}.zip"
            try:
                with zipfile.ZipFile(preview_archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                    for preview in preview_files:
                        archive.write(preview, arcname=preview.name)
                await message.answer_document(document=FSInputFile(preview_archive_path), caption="📎 PNG-превью (архив)")
            except Exception:
                logger.exception("Failed to send preview archive %s", preview_archive_path)
        else:
            for preview in preview_files:
                try:
                    await message.answer_photo(photo=FSInputFile(preview), caption=f"Preview: {preview.name}")
                except Exception:
                    logger.exception("Failed to send preview %s", preview)

    for temp_path in (archive_path, preview_archive_path):
        if temp_path and temp_path.exists():
            try:
                temp_path.unlink()
            except OSError as exc:
                logger.warning("Failed to remove temporary archive %s: %s", temp_path, exc)

    await ack.edit_text(
        get_text(lang, "files_sent_summary", sent=sent, total=len(new_files))
    )

    audit_summary = None
    try:
        audit_summary = await perform_self_audit(input_path, new_files)
    except Exception:
        logger.exception("Self-audit pipeline failed for %s", input_path.name)

    if audit_summary:
        bitrate_text = (
            f"{audit_summary.avg_bitrate_mbps:.1f} Mbps"
            if audit_summary.avg_bitrate_mbps
            else "n/a"
        )
        phash_icon = "✅" if audit_summary.phash_ok else "⚠️"
        diversified = "Yes" if audit_summary.encoder_diversified else "No"
        timestamps_label = "Yes" if audit_summary.timestamps_randomized else "No"

        fallback_line = None
        if audit_summary.low_uniqueness_fallback:
            fallback_line = (
                audit_summary.low_uniqueness_message
                or "⚠️ Low uniqueness fallback triggered."
            )

        warning_text = ""
        if audit_summary.status_warnings:
            humanized: List[str] = []
            for raw in audit_summary.status_warnings:
                if fallback_line and raw.strip() == fallback_line.strip():
                    continue
                cleaned = raw.replace("WARNING_", "").replace(";", ", ")
                humanized.append(cleaned.replace("_", " ").title())
            if humanized:
                warning_text = f"⚠️ Status warnings: {', '.join(humanized)}"

        report_lines = [
            f"🧾 Uniclon Audit Report ({audit_summary.source_name})",
            f"🎥 Copies: {audit_summary.copies_created}",
            f"📈 Avg bitrate: {bitrate_text}",
            f"🎞️ SSIM: {audit_summary.mean_ssim:.3f} | PSNR: {audit_summary.mean_psnr:.1f} dB",
            f"🧩 Avg pHash diff: {audit_summary.mean_phash_diff:.1f} {phash_icon}",
            f"🧠 Encoder/software diversified: {diversified}",
            f"🕒 Timestamps randomized: {timestamps_label}",
            f"🛡 Metadata sanitized: {'Yes' if audit_summary.metadata_sanitized else 'No'}",
        ]
        if fallback_line:
            report_lines.insert(1, fallback_line)
        if warning_text:
            report_lines.append(warning_text)
        report_lines.extend(
            [
                "",
                f"{audit_summary.trust_emoji} TRUST SCORE: {audit_summary.trust_score:.1f} / 10 — {audit_summary.trust_label}",
                "📎 Отчёт: uniclon_report.csv",
            ]
        )

        await message.answer("\n".join(report_lines))

        if audit_summary.report_path.exists():
            try:
                await message.answer_document(
                    document=FSInputFile(audit_summary.report_path),
                    caption="uniclon_report.csv",
                )
            except Exception:
                logger.exception("Failed to send audit file %s", audit_summary.report_path)

    if CLEAN_UP_INPUT:
        try:
            os.remove(input_path)
        except FileNotFoundError:
            pass
        except Exception:
            logger.exception("Failed to remove input file %s", input_path)
        else:
            logger.info("Temporary file %s deleted.", input_path)


@router.message()
async def fallback_check(message: Message) -> None:
    if message.text and message.text.startswith(("/", "🔄")):
        return

    if message.video or (
        message.document and message.document.mime_type == "video/mp4"
    ):
        return
    await message.answer(
        "❌ Похоже, ты не отправил видеофайл (.mp4). Попробуй ещё раз."
    )
