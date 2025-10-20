import asyncio
import logging
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# REGION AI: imports
from adaptive_tuner import get_tuned_params, record_render_result
from config import SCRIPT_PATH, OUTPUT_DIR, NO_DEVICE_INFO, PLATFORM_PRESETS
from report_builder import build_uniqueness_report
from render_queue import acquire_render_slot
# END REGION AI


logger = logging.getLogger(__name__)

# REGION AI: adaptive tuning bootstrap
_ADAPTIVE_ENV, _ADAPTIVE_META = get_tuned_params()
os.environ.update(_ADAPTIVE_ENV)
_avg_text = "-" if _ADAPTIVE_META.get("uniq_avg") is None else f"{_ADAPTIVE_META['uniq_avg']:.1f}"
logger.info("🎚 Adaptive tuner applied: mode=%s | UniqScore_avg=%s", _ADAPTIVE_META.get("mode", "neutral"), _avg_text)
# END REGION AI

# REGION AI: script path logging
logger.info("Using processing script: %s", SCRIPT_PATH)
# END REGION AI


# REGION AI: smart render queue wrapper
async def run_script_with_logs(
    input_file: Path, copies: int, cwd: Path, profile: str, quality: str
) -> Tuple[int, str]:
    try:
        priority = max(1, int(os.getenv("UNICLON_RENDER_PRIORITY", "1")))
    except ValueError:
        priority = 1
    release = await acquire_render_slot(input_file.name, copies, priority)
    try:
        return await _run_script_core(input_file, copies, cwd, profile, quality)
    finally:
        release()
# END REGION AI


async def _run_script_core(
    input_file: Path, copies: int, cwd: Path, profile: str, quality: str
) -> Tuple[int, str]:
    """Запускает bash-скрипт и возвращает (returncode, объединённые логи)."""
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Script not found: {SCRIPT_PATH}")

    # ensure +x
    try:
        SCRIPT_PATH.chmod(SCRIPT_PATH.stat().st_mode | 0o111)
    except Exception:
        pass

    normalized_profile = (profile or "").strip().lower()
    if normalized_profile == "default":
        normalized_profile = ""

    # REGION AI: supported platform profiles
    valid_profiles = set(PLATFORM_PRESETS.keys())
    preset_details: Optional[Dict[str, object]] = None
    # END REGION AI
    profile_args: List[str] = []
    if normalized_profile in valid_profiles:
        profile_args = ["--profile", normalized_profile]
        preset_details = PLATFORM_PRESETS.get(normalized_profile)
        if preset_details:
            display_name = str(preset_details.get("display_name", normalized_profile.title()))
            resolution = preset_details.get("resolution", "?")
            fps_range = preset_details.get("fps_range", [])
            bitrate_range = preset_details.get("bitrate_range", [])
            audio_rates = preset_details.get("audio_rates", [])
            codec_profile = preset_details.get("codec_profile", "?")
            codec_level = preset_details.get("codec_level", "?")
            fps_repr = "-".join(str(v) for v in fps_range) if fps_range else "-"
            bitrate_repr = "-".join(str(v) for v in bitrate_range) if bitrate_range else "-"
            audio_repr = ",".join(str(v) for v in audio_rates) if audio_rates else "-"
            logger.info(
                "🎯 Профиль: %s (%s) | resolution=%s | fps=%s | bitrate=%s kbps | audio=%s Hz | codec=%s@L%s",
                display_name,
                normalized_profile,
                resolution,
                fps_repr,
                bitrate_repr,
                audio_repr,
                codec_profile,
                codec_level,
            )
    elif normalized_profile:
        logger.warning(
            "Unknown profile '%s' for %s; invoking script without --profile",
            normalized_profile,
            input_file.name,
        )
        normalized_profile = ""

    normalized_quality = (quality or "").strip().lower()
    quality_args: List[str] = []
    if normalized_quality in {"high", "std"}:
        quality_args = ["--quality", normalized_quality]
    else:
        normalized_quality = "std"
        quality_args = ["--quality", normalized_quality]

    device_args: List[str] = ["--no-device-info"] if NO_DEVICE_INFO else []
    music_variant_flag = os.getenv("UNICLON_ENABLE_MUSIC_VARIANT", "0").strip().lower()
    music_variant_enabled = music_variant_flag in {"1", "true", "yes", "on"}
    music_variant_args: List[str] = ["--music-variant"] if music_variant_enabled else []

    # REGION AI: task logging state
    logger.info(
        "🚀 Запуск скрипта: src=%s | copies=%s | profile=%s | q=%s | music=%s",
        input_file.name,
        copies,
        normalized_profile or "-",
        normalized_quality,
        "on" if music_variant_enabled else "off",
    )
    clip_hint = ""
    last_target: Optional[str] = None
    duration_map: Dict[str, str] = {}
    success_files: List[str] = []
    failure_names: List[str] = []
    # END REGION AI
    env = os.environ.copy()
    env["OUTPUT_DIR"] = str(OUTPUT_DIR)
    env["PREVIEW_DIR"] = str(OUTPUT_DIR / "previews")

    proc = await asyncio.create_subprocess_exec(
        str(SCRIPT_PATH),
        input_file.name,
        str(int(copies)),
        *profile_args,
        *quality_args,
        *device_args,
        *music_variant_args,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=env,
    )

    lines: List[str] = []
    last_nonempty: Optional[str] = None
    assert proc.stdout is not None
    async for raw in proc.stdout:
        decoded = raw.decode(errors="replace")
        lines.append(decoded)
        message = decoded.rstrip("\n")
        stripped = message.strip()
        if stripped:
            last_nonempty = stripped
        if message:
            logger.info(
                "[%s|copies=%s|profile=%s] %s",
                input_file.name,
                copies,
                f"{normalized_profile or '-'}|q={normalized_quality}",
                message,
            )
        else:
            logger.info(
                "[%s|copies=%s|profile=%s]",
                input_file.name,
                copies,
                f"{normalized_profile or '-'}|q={normalized_quality}",
            )

        if stripped and "clip_start=" in stripped:
            token = stripped.split("clip_start=", 1)[1].split()[0].rstrip(",")
            clip_hint = token[:-1] if token.endswith("s") else token
        if stripped.startswith("▶️"):
            parts = stripped.split("→", 1)
            if len(parts) == 2:
                rhs = parts[1]
                target = rhs.split("|", 1)[0].strip()
                params_text = rhs.split("|", 1)[1] if "|" in rhs else ""
                tokens = {key: value.rstrip(",") for key, value in (seg.split("=", 1) for seg in params_text.split() if "=" in seg)}
                ss_value = clip_hint or tokens.get("ss", "0")
                duration_map[target] = tokens.get("duration", "-")
                logger.info("🎛 Параметры копии: file=%s | fps=%s | bitrate=%s | ss=%s | duration=%s", target, tokens.get("fps", "-"), tokens.get("br", "-"), ss_value, duration_map[target])
                last_target = target
                clip_hint = ""
        elif stripped.startswith("✅ done:"):
            target = stripped.split("✅ done:", 1)[1].strip()
            success_files.append(target)
            logger.info("✅ Копия завершена: file=%s | duration=%s", target, duration_map.get(target, "-"))
        elif stripped.startswith("❌"):
            failure = Path(last_target or input_file.name).name
            if failure not in failure_names:
                failure_names.append(failure)

    rc = await proc.wait()
    logger.info("✅ %s копии успешно", len(success_files))
    if failure_names:
        logger.error("❌ %s копии с ошибкой: %s", len(failure_names), ", ".join(failure_names))
    tail = "".join(lines[-10:])
    if rc != 0:
# REGION AI: tolerant script exit
        if last_target:
            base_name = Path(last_target).name
            if base_name not in failure_names:
                failure_names.append(base_name)
                logger.error("❌ %s копии с ошибкой: %s", len(failure_names), ", ".join(failure_names))
        logger.warning(
            "Script %s finished with code %s for %s (copies=%s). Last line: %s. Tail logs:\n%s",
            SCRIPT_PATH,
            rc,
            input_file.name,
            copies,
            last_nonempty or "",
            tail,
        )
        return rc, "".join(lines)
# END REGION AI

    # fix: агрегация UniqScore отчёта
    # REGION AI: uniqueness reporting
    try:
        report_result = build_uniqueness_report(success_files, copies)
    except Exception:
        logger.exception("Failed to build uniqueness report")
    else:
        if report_result:
            report_payload, summary_line, level_emoji = report_result
            try:
                record_render_result(report_payload)
            except Exception:
                logger.debug("Adaptive tuner history update failed", exc_info=True)
            lines.append(summary_line + "\n")
            try:
                from handlers import broadcast_uniqscore_indicator
            except ImportError:
                pass
            except Exception:
                logger.debug("UniqScore notifier import failed", exc_info=True)
            else:
                try:
                    broadcast_uniqscore_indicator(level_emoji)
                except Exception:
                    logger.debug("UniqScore notifier call failed", exc_info=True)
    # END REGION AI

    return rc, "".join(lines)


async def list_new_mp4s(since_ts: float, name_hint: str = "") -> List[Path]:
    files: List[Path] = []
    for p in OUTPUT_DIR.glob("*.mp4"):
        try:
            if p.stat().st_mtime >= since_ts - 0.5:
                files.append(p)
        except FileNotFoundError:
            continue
    files.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return files


async def probe_video_duration(path: Path) -> Optional[float]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        logger.warning("ffprobe not available to measure duration")
        return None

    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        logger.warning(
            "ffprobe failed for %s: %s", path, stderr.decode(errors="replace").strip()
        )
        return None

    try:
        return float(stdout.decode().strip())
    except (TypeError, ValueError):
        return None
