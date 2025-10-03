import os
from pathlib import Path
from dotenv import load_dotenv

# Всегда корень проекта (папка на уровень выше /uniclon)
BASE_DIR = Path(__file__).resolve().parent.parent

# Грузим .env из корня
load_dotenv(BASE_DIR / ".env")

SCRIPT_PATH = BASE_DIR / "process_protective_v1.6.sh"
OUTPUT_DIR = BASE_DIR / "Новая папка"
OUTPUT_DIR.mkdir(exist_ok=True)

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
if not BOT_TOKEN:
    raise SystemExit("[ERROR] TELEGRAM_BOT_TOKEN is not set. Put it into .env")

MAX_COPIES = 20
LOG_TAIL_CHARS = 3500
CLEAN_UP_INPUT = False
BOT_API_BASE = os.getenv("BOT_API_BASE", "").strip()
