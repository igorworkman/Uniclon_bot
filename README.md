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
├── tests/
│   └── selfcheck.sh
├── uniclon_audit.sh
├── uniclon_bot.py
├── utils/
│   ├── helpers.sh
│   ├── logger.sh
│   └── safe_exec.sh
├── utils.py
└── verify_modular_env.sh
```

### 📦 modules/
- `modules/_index.sh` — единая точка подключения shell-модулей и общих утилит.
- `modules/audio_utils.sh` — построение аудио-цепочек, проверка поддержки фильтров и мягкие fallback-профили.
- `modules/combo_engine.sh` — генератор комбинаций фильтров с защитой от повторов и безопасным экранированием.
- `modules/core_init.sh` — инициализация окружения: каталоги, PATH и временные директории проекта.
- `modules/creative_utils.sh` — выбор интро, LUT и безопасная упаковка vf-цепочек для ffmpeg.
- `modules/executor.py` — очистка фильтров, коррекция crop/tempo и восстановление цепочек перед повторным рендером.
- `modules/fallback_manager.sh` — логика мягких ретраев при низкой уникальности и контроль лимитов попыток.
- `modules/ffmpeg_driver.sh` — обёртки для ffmpeg/ffprobe с ретраями, проверками фильтров и предпросмотром команд.
- `modules/file_ops.sh` — сервисы работы с файловой системой, очистки временных артефактов и touch-операций.
- `modules/helpers.sh` — вспомогательные функции разбора combo-профилей и применения контекстов рендера.
- `modules/manifest.sh` — управление manifest.csv: обновление схемы, экранирование полей и записи отчётов.
- `modules/metadata.py` — генерация свежих encoder/software тегов и временных меток под выбранный профиль.
- `modules/metrics.sh` — расчёт SSIM/PSNR/pHash и агрегация метрик уникальности для копий.
- `modules/orchestrator.py` — самоисцеляющийся ретрай ffmpeg с упрощением фильтров и обновлением метаданных.
- `modules/permissions.sh` — установка исполняемых прав для защитных скриптов и модулей.
- `modules/report_builder.sh` — сбор статистики по копиям, расчёт UniqScore и выгрузка CSV/JSON отчётов.
- `modules/rng_utils.sh` — детерминированный генератор случайных чисел на основе md5-стримов.
- `modules/time_utils.sh` — обработка временных аргументов и безопасная функция clip_start().
- `modules/utils/__init__.py` — пространство имён для python-утилит внутри `modules/utils`.
- `modules/utils/meta_utils.py` — генерация связок временных меток и файловых epoch для метаданных.
- `modules/utils/video_tools.py` — построение аудио эквалайзера, профилей и вспомогательных CLI команд.
- `process_protective_v1.6.sh` — включает рандомизацию таймштампов PTS и случайный выбор encoder/software для итоговых файлов.
### 🧠 core/
- `modules/core/audit_manager.py` — вычисление trust score и валидация профиля кодирования.
- `modules/core/presets.py` — набор целевых видео-профилей (TikTok, Instagram, YouTube) с параметрами кодека.
- `modules/core/seed_utils.py` — создание стабильных seed и выдача rng для воспроизводимых выборок.
### 🤖 handlers/
- `handlers.py` — aiogram-роутеры, парсинг входящих сообщений, запуск пайплайна и обработка ошибок.
- `handlers.FSM` — класс состояний внутри `handlers.py`, управляющий шагами диалога (старт, настройки, загрузка, предпросмотры).
### 🌐 locales/
- `locales/__init__.py` — загрузка JSON-файлов локализаций и предоставление API для бота.
- `locales/en.json` — английские строки интерфейса и подсказок.
- `locales/ru.json` — русские локализованные сообщения и реакции бота.
### 🛠 services/
- `services/__init__.py` — экспорт доступных сервисных модулей.
- `services/video_processor.py` — асинхронный оркестратор рендеринга: семафоры, очистка метаданных и запуск защитного скрипта.
### 🔧 tools/
- `tools/check_bindings.sh` — проверка того, что все функции модулей доступны защитному скрипту.
- `tools/extract_contract.sh` — генерация контракта с перечнем функций shell-модулей для Codex.
### 🧪 tests/
- `tests/selfcheck.sh` — автоматическая проверка стабильности пайплайна Uniclon.
### 🧰 utils/
- `utils/helpers.sh` — парсинг аргументов CLI, clamp/uuid и подготовка параметров запуска.
- `utils/logger.sh` — консольный логгер с уровнями INFO/WARN/ERROR для shell-скриптов.
- `utils/safe_exec.sh` — безопасный запуск команд с ретраями и проверкой статусов выполнения.
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
