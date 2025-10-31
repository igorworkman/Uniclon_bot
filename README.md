# 🧬 Uniclon — Интеллектуальный видеоуникализатор нового поколения

Uniclon — это автономный Telegram-бот и CLI-инструмент для продвинутой уникализации видео.
Он создан как ответ на современные антидубликатные алгоритмы TikTok, Instagram (Meta) и других платформ.

🎯 **Миссия проекта:** сделать видео *технически уникальным* и правдоподобным, чтобы оно воспринималось платформами как оригинальное, а не как копия.

---

## 🧠 Почему появился Uniclon

В 2024–2025 годах TikTok и Meta усилили анализ загружаемого видео.  
Их системы проверяют:
- EXIF и metadata (модель камеры, encoder, creation_time, software tag),
- битрейт и кодек-профиль,
- шаблоны совпадений по hash и pHash,
- признаки массового репоста (идентичные файлы, таймштампы, software tags),
- доверенные источники (видео из TikTok / CapCut получают приоритет).

🎯 Uniclon создавался именно как решение для **контент-мейкеров, агентств и автоматизированных сетей**, которым нужно:
- масштабно постить видео без банов за дубликаты;
- сохранять естественный вид файлов;
- менять технические отпечатки: bitrate, resolution, duration, EXIF и “software tags”.

---

## ⚙️ Ключевые особенности Uniclon

- 🧩 **Модульная система (v1.6+)**  
  Каждая стадия обработки — отдельный модуль (`modules/*.sh`), отвечающий за фильтры, метаданные, отчётность и fallback-логику.

- 🎛 **RUN_COMBOS Engine**  
  Генератор динамических комбинаций фильтров, создающий уникальные визуальные и аудио-профили при каждом запуске.

- 🧠 **Content & Metadata Shield**  
  Имитация реальных EXIF-тегов, случайное варьирование битрейта, encoder-тегов и временных меток.

- 🎬 **Безупречная ffmpeg-интеграция**  
  Модуль `combo_engine.sh` внедряет безопасное экранирование фильтров (`safe_vf`, `safe_eval`), предотвращая ошибки при сложных выражениях.

- 📊 **Метрики и отчётность**  
  После каждого рендера формируются:
  - `SSIM`, `PSNR`, `pHash`, `UniqScore`
  - HTML/JSON отчёты (`report_builder.sh`)

- 🔒 **Локальная безопасность**  
  Все операции выполняются локально — видео не покидает вашу машину.

---

## 📂 Архитектура проекта (v1.7 Verified)

> Структура соответствует коммиту “feat: echo adjusted variant logs and safe array defaults” (27 минут назад).

```
Uniclon_bot/
├── .env
├── .gitignore
├── README.md
├── adaptive_tuner.py
├── audit.py
├── bootstrap_compat.sh
├── bot.py
├── codex/
│   └── describe/
│       └── bot_purpose.yaml
├── codex_contract.yml
├── codex_rules.md
├── collect_meta.sh
├── config.py
├── downloader.py
├── executor.py
├── handlers.py
├── init.py
├── locales/
│   ├── __init__.py
│   ├── en.json
│   └── ru.json
├── modules/
│   ├── _index.sh
│   ├── audio_utils.sh
│   ├── combo_engine.sh
│   ├── core_init.sh
│   ├── creative_utils.sh
│   ├── executor.py
│   ├── fallback_manager.sh
│   ├── ffmpeg_driver.sh
│   ├── file_ops.sh
│   ├── helpers.sh
│   ├── manifest.sh
│   ├── metadata.py
│   ├── metrics.sh
│   ├── orchestrator.py
│   ├── permissions.sh
│   ├── report_builder.sh
│   ├── rng_utils.sh
│   ├── time_utils.sh
│   ├── core/
│   │   ├── audit_manager.py
│   │   ├── presets.py
│   │   └── seed_utils.py
│   └── utils/
│       ├── __init__.py
│       ├── meta_utils.py
│       └── video_tools.py
├── orchestrator.py
├── phash_check.py
├── process_protective_v1.6.sh
├── quality_check.sh
├── render_queue.py
├── report_builder.py
├── requirements.txt
├── scan_unescaped_parentheses.sh
├── services/
│   ├── __init__.py
│   └── video_processor.py
├── tools/
│   ├── check_bindings.sh
│   └── extract_contract.sh
├── uniclon_audit.sh
├── uniclon_bot.py
├── utils/
│   ├── helpers.sh
│   ├── logger.sh
│   └── safe_exec.sh
├── utils.py
└── verify_modular_env.sh
```

### 🧩 Core Modules

- `modules/core/` — управление аудитом, предустановками и генерацией семян уникализации.
- `modules/utils/` — общие утилиты для работы с метаданными и видеопост-обработкой.

### 🌐 Localization

- `locales/en.json` и `locales/ru.json` — ключи интерфейса на английском и русском, инициализируемые через `locales/__init__.py`.

### 🛠 Service & Diagnostic Tools

- Скрипты обслуживания: `bootstrap_compat.sh`, `collect_meta.sh`, `process_protective_v1.6.sh`, `quality_check.sh`, `scan_unescaped_parentheses.sh`, `uniclon_audit.sh`, `verify_modular_env.sh`.
- Инструменты интеграции: `tools/check_bindings.sh`, `tools/extract_contract.sh`.

### 🧠 Services

- `services/video_processor.py` — сервисный слой для высокоуровневой оркестрации рендеринга.

---

## 🧬 Технологии и подходы

- **ffmpeg advanced pipelines** — модульная сборка фильтров и постобработки  
- **AI-driven combo generator** — динамический подбор фильтров и параметров  
- **Metadata faker** — создание правдоподобных EXIF/Software-тегов  
- **C2PA-bypass layer** — имитация нативных источников контента  
- **pHash rotation** — контроль перцептивных хэшей и уровня схожести

---

## 🚀 Почему Uniclon — лучший уникализатор видео 2025 года

Uniclon — не просто скрипт. Это инженерная экосистема, которая соединяет
машинную уникализацию, мета-анализ и ffmpeg-оптимизацию в единый поток.

💡 Он делает именно то, чего ждёт алгоритм TikTok — *естественное отличие*:
новые кадры, уникальные теги, корректный кодек, реалистичные метаданные.

🧠 **Каждый рендер — новая цифровая личность видео.**

---

## 🛠 Запуск

```bash
python3 uniclon_bot.py
# или CLI-режим:
./process_protective_v1.6.sh input.mp4 3
```

---

## 📜 Лицензия

© 2025 Uniclon Labs. Все права защищены.
