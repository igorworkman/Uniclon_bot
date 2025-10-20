import os
from pathlib import Path

from dotenv import load_dotenv

# REGION AI: imports
import warnings
# END REGION AI

# REGION AI: centralized configuration
BASE_DIR = Path(__file__).resolve().parent.parent

load_dotenv(BASE_DIR / ".env")

_allow_external = os.getenv("UNICLON_ALLOW_EXTERNAL_SCRIPT", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
_repo_script = (BASE_DIR / "process_protective_v1.6.sh").resolve()

_script_env = os.getenv("SCRIPT_PATH", "").strip()
if _script_env:
    _script_path = Path(_script_env).expanduser()
    if not _script_path.is_absolute():
        _script_path = BASE_DIR / _script_path
    _script_path = _script_path.resolve()
else:
    _script_path = _repo_script

if _repo_script.exists() and _script_env:
    _original_script_path = _script_path
    try:
        _script_path.relative_to(BASE_DIR)
        _inside_repo = True
    except ValueError:
        _inside_repo = False
    if not _inside_repo and not _allow_external:
        warnings.warn(
            (
                "External SCRIPT_PATH '%s' ignored; using repo script '%s'"
                % (_original_script_path, _repo_script)
            ),
            RuntimeWarning,
        )
        _script_path = _repo_script

SCRIPT_PATH = _script_path

_output_dir_env = os.getenv("OUTPUT_DIR", "").strip()
if not _output_dir_env:
    _output_dir_env = "Новая папка"
_output_dir_path = Path(_output_dir_env).expanduser()
if not _output_dir_path.is_absolute():
    _output_dir_path = BASE_DIR / _output_dir_path
OUTPUT_DIR = _output_dir_path
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

CHECKS_DIR = BASE_DIR / "checks"
CHECKS_DIR.mkdir(parents=True, exist_ok=True)

# REGION AI: platform presets
PLATFORM_PRESETS = {
    "tiktok": {
        "display_name": "TikTok",
        "resolution": "1080x1920",
        "fps_range": [30, 60],
        "bitrate_range": [2800, 5000],
        "audio_bitrate_range": [96, 160],
        "audio_rates": [44100],
        "codec_profile": "high",
        "codec_level": "4.0",
    },
    "instagram": {
        "display_name": "Instagram",
        "resolution": "1080x1920",
        "fps_range": [24, 25, 30],
        "bitrate_range": [2500, 4500],
        "audio_bitrate_range": [96, 160],
        "audio_rates": [44100],
        "codec_profile": "high",
        "codec_level": "4.0",
    },
    "youtube": {
        "display_name": "YouTube Shorts",
        "resolution": "1080x1920",
        "fps_range": [24, 30, 60],
        "bitrate_range": [3000, 5500],
        "audio_bitrate_range": [96, 160],
        "audio_rates": [44100, 48000],
        "codec_profile": "high",
        "codec_level": "4.2",
    },
}
# END REGION AI


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
if not BOT_TOKEN:
    raise SystemExit("[ERROR] TELEGRAM_BOT_TOKEN is not set. Put it into .env")

MAX_COPIES = 20
LOG_TAIL_CHARS = 3500
CLEAN_UP_INPUT = False
BOT_API_BASE = os.getenv("BOT_API_BASE", "").strip()

NO_DEVICE_INFO = _env_flag("UNICLON_NO_DEVICE_INFO", False)
FORCE_ZIP_ARCHIVE = _env_flag("UNICLON_FORCE_ZIP", False)
# END REGION AI
