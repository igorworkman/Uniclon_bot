import asyncio
import csv
import logging
import os

import re

import json
import random
import time

from pathlib import Path
from typing import Dict, List, Optional, Tuple

# REGION AI: imports
from adaptive_tuner import get_tuned_params, record_render_result
from config import ECO_MODE, SCRIPT_PATH, OUTPUT_DIR, NO_DEVICE_INFO, PLATFORM_PRESETS
from report_builder import build_uniqueness_report
from render_queue import acquire_render_slot
from orchestrator import add_task as orchestrator_add_task, finish_task as orchestrator_finish_task
from services.video_processor import run_protective_process_async
# END REGION AI


logger = logging.getLogger(__name__)


_SAVED_LINE_RE = re.compile(
    r"^\[Uniclon v1\.7\] Saved as: (?P<name>[A-Z]{3}_\d{8}_\d{6}_(?P<hash>[0-9a-f]{4})\.mp4)\s+\(seed=(?P<seed>[0-9.]+),\s*software=(?P<software>.+)\)$"
)

RUN_LOG_PATH = OUTPUT_DIR / "uniclon_run.log"
_CPU_CORES = os.cpu_count() or 1
_BASE_MAX_JOBS = max(1, min(2, (_CPU_CORES // 2) or 1))
_FFMPEG_LIMITS = {False: asyncio.Semaphore(_BASE_MAX_JOBS), True: asyncio.Semaphore(1)}
_COPY_SEMAPHORE = asyncio.Semaphore(1)


def _load_manifest_metadata(files: List[str]) -> Dict[str, Dict[str, str]]:
    manifest_path = OUTPUT_DIR / "manifest.csv"
    targets = {Path(item).name for item in files if item}
    if not manifest_path.exists() or not targets:
        return {}
    try:
        with manifest_path.open("r", encoding="utf-8") as handle:
            return {
                Path(raw).name: {
                    "seed": (row.get("seed") or "").strip(),
                    "software": (row.get("software") or "").strip(),
                }
                for row in csv.DictReader(handle)
                if (raw := (row.get("filename") or row.get("file") or "").strip())
                and Path(raw).name in targets
            }
    except Exception:
        logger.debug("Manifest read failed for run log", exc_info=True)
        return {}


def _log_copy_run(
    copy_meta: Dict[int, Dict[str, str]],
    success_files: List[str],
    copies: int,
    eco_active: bool,
    eco_delay: Optional[float],
) -> None:
    manifest_sources = success_files + [meta.get("file", "") for meta in copy_meta.values()]
    manifest_data = _load_manifest_metadata(manifest_sources)
    entries: List[Dict[str, object]] = []
    for idx in range(1, copies + 1):
        info = copy_meta.get(idx, {})
        file_name = info.get("file") or (success_files[idx - 1] if idx - 1 < len(success_files) else "")
        manifest_key = Path(file_name).name if file_name else ""
        manifest_row = manifest_data.get(manifest_key, {})
        seed = info.get("seed") or manifest_row.get("seed", "")
        software = info.get("software") or manifest_row.get("software", "")
        message = (
            f"[Uniclon v1.7] Copy #{idx}: seed={seed or '-'}, "
            f"software={software or '-'}, file={file_name or '-'}"
        )
        if eco_active and eco_delay:
            message += f", EcoMode active ({eco_delay:.1f}s delay)"
        elif eco_active:
            message += ", EcoMode active"
        logger.info(message)
        entries.append(
            {
                "copy": idx,
                "file": file_name,
                "seed": seed,
                "software": software,
                "eco_mode": eco_active,
                "eco_delay": round(eco_delay, 3) if eco_delay else None,
                "timestamp": time.time(),
            }
        )
    if not entries:
        return
    try:
        with RUN_LOG_PATH.open("a", encoding="utf-8") as handle:
            for entry in entries:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        logger.debug("Run log write failed", exc_info=True)


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
    ticket = await orchestrator_add_task(input_file.name, copies, priority)
    release = None
    try:
        release = await acquire_render_slot(input_file.name, copies, priority)
    except Exception:
        try:
            await orchestrator_finish_task(ticket)
        except Exception:
            logger.debug("Orchestrator finalize on slot failure", exc_info=True)
        raise
    try:
        try:
            result = await _run_script_core(
                input_file,
                copies,
                cwd,
                profile,
                quality,
                orchestrator_ticket=ticket,
            )
        except Exception:
            try:
                await orchestrator_finish_task(ticket)
            except Exception:
                logger.debug("Orchestrator finalize on error failed", exc_info=True)
            raise
        await orchestrator_finish_task(ticket, ticket.get("metrics"))
        return result
    finally:
        if release:
            release()
# END REGION AI


async def _run_script_core(
    input_file: Path,
    copies: int,
    cwd: Path,
    profile: str,
    quality: str,
    orchestrator_ticket: Optional[Dict[str, object]] = None,
) -> Tuple[int, str]:
    """Запускает bash-скрипт и возвращает (returncode, объединённые логи)."""
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Script not found: {SCRIPT_PATH}")

    if orchestrator_ticket is not None:
        orchestrator_ticket["metrics"] = None

    eco_active = bool(ECO_MODE or copies > 4)
    eco_delay: Optional[float] = None
    copy_meta: Dict[int, Dict[str, str]] = {}

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
    saved_meta: Dict[str, Tuple[str, str]] = {}
    # END REGION AI
    env = os.environ.copy()
    if orchestrator_ticket:
        env.update({k: str(v) for k, v in orchestrator_ticket.get("env", {}).items()})
        if orchestrator_ticket.get("mode") and orchestrator_ticket.get("mode") != "neutral":
            logger.info(
                "🎛 Orchestrator mode: %s | %s",
                orchestrator_ticket["mode"],
                input_file.name,
            )
    env["OUTPUT_DIR"] = str(OUTPUT_DIR)
    env["PREVIEW_DIR"] = str(OUTPUT_DIR / "previews")

    sem = _FFMPEG_LIMITS[eco_active]
    await sem.acquire()
    try:
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
    except Exception:
        sem.release()
        raise

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
            saved_match = _SAVED_LINE_RE.match(stripped)
            if saved_match:
                name = saved_match.group("name")
                seed_text = saved_match.group("seed")
                actual_hash = saved_match.group("hash")
                try:
                    expected_hash = f"{int(float(seed_text) * 65535) & 0xFFFF:04x}"
                except ValueError:
                    expected_hash = None
                if expected_hash and expected_hash != actual_hash:
                    logger.warning(
                        "Seed hash mismatch: %s (seed=%s expected=%s actual=%s)",
                        name,
                        seed_text,
                        expected_hash,
                        actual_hash,
                    )
                if any(seed_text == existing_seed for existing_seed, _ in saved_meta.values()):
                    logger.warning("Duplicate seed detected for %s (seed=%s)", name, seed_text)
                saved_meta[name] = (seed_text, saved_match.group("software").strip())
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

        if stripped.startswith("DEBUG copy="):
            tokens = {}
            for segment in stripped.replace("DEBUG", "", 1).strip().split():
                if "=" in segment:
                    key, value = segment.split("=", 1)
                    tokens[key] = value.rstrip(",")
            try:
                copy_idx = int(tokens.get("copy", "0"))
            except ValueError:
                copy_idx = 0
            if copy_idx:
                info = copy_meta.setdefault(copy_idx, {})
                if tokens.get("seed"):
                    info["seed"] = tokens["seed"]

        if stripped.startswith("▶️"):
            target = ""
            try:
                header, rhs = stripped.split("→", 1)
                block = header.split("[", 1)[1].split("]", 1)[0]
                copy_idx = int(block.split("/", 1)[0])
                target = rhs.split("|", 1)[0].strip()
            except Exception:
                copy_idx = len(copy_meta) + 1
                if "→" in stripped:
                    target = stripped.split("→", 1)[1].split("|", 1)[0].strip()
            if target:
                info = copy_meta.setdefault(copy_idx, {})
                info["file"] = target

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
    sem.release()
    logger.info("✅ %s копии успешно", len(success_files))
    if failure_names:
        logger.error("❌ %s копии с ошибкой: %s", len(failure_names), ", ".join(failure_names))
    tail = "".join(lines[-10:])
    if eco_active:
        eco_delay = random.uniform(1.0, 3.0)
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
        if orchestrator_ticket is not None:
            orchestrator_ticket["metrics"] = None
        _log_copy_run(copy_meta, success_files, copies, eco_active, eco_delay)
        if eco_active and eco_delay:
            logger.info("[EcoMode] Cooling CPU load between runs (delay=%.1fs)", eco_delay)
            await asyncio.get_running_loop().run_in_executor(None, time.sleep, eco_delay)
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
            if orchestrator_ticket is not None:
                orchestrator_ticket["metrics"] = report_payload
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
        elif orchestrator_ticket is not None:
            orchestrator_ticket["metrics"] = None
    # END REGION AI

    _log_copy_run(copy_meta, success_files, copies, eco_active, eco_delay)
    if eco_active and eco_delay:
        logger.info("[EcoMode] Cooling CPU load between runs (delay=%.1fs)", eco_delay)
        await asyncio.get_running_loop().run_in_executor(None, time.sleep, eco_delay)

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


async def process_copies_sequentially(
    input_path: Path,
    copies: int,
    profile: str,
    quality: str,
    *,
    timeout: float = 300.0,
    retries: int = 1,
) -> List[Dict[str, object]]:
    results = []
    for idx in range(1, copies + 1):
        attempt = 0
        while True:
            try:
                async with _COPY_SEMAPHORE:
                    payload = await asyncio.wait_for(
                        run_protective_process_async(
                            input_path.name,
                            1,
                            profile,
                            quality,
                        ),
                        timeout=timeout,
                    )
                outputs = [Path(p) for p in payload.get("outputs", []) if p]
                if not outputs:
                    raise RuntimeError("no output produced")
                results.append({"index": idx, "path": outputs[0]})
                break
            except asyncio.TimeoutError:
                results.append({"index": idx, "error": "timeout"})
                break
            except Exception as exc:  # noqa: BLE001
                if attempt >= retries:
                    logger.exception("Copy #%d failed: %s", idx, exc)
                    results.append({"index": idx, "error": str(exc)})
                    break
                attempt += 1
                await asyncio.sleep(2)
        if idx < copies:
            await asyncio.sleep(random.uniform(0.5, 1.2))
    return results
