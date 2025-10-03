from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Dict

_LOCALES_DIR = Path(__file__).resolve().parent
_DEFAULT_LANGUAGE = "ru"


@lru_cache(maxsize=None)
def _load_locale(lang: str) -> Dict[str, str]:
    path = _LOCALES_DIR / f"{lang}.json"
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _normalize_lang(lang: str | None) -> str:
    if not lang:
        return _DEFAULT_LANGUAGE
    normalized = lang.split("-")[0].lower()
    if (_LOCALES_DIR / f"{normalized}.json").exists():
        return normalized
    return _DEFAULT_LANGUAGE


def get_text(lang: str | None, key: str, **kwargs) -> str:
    normalized = _normalize_lang(lang)
    messages = _load_locale(normalized)
    text = messages.get(key)
    if text is None and normalized != _DEFAULT_LANGUAGE:
        text = _load_locale(_DEFAULT_LANGUAGE).get(key, key)
    elif text is None:
        text = key
    if kwargs:
        try:
            return text.format(**kwargs)
        except KeyError:
            return text
    return text


__all__ = ["get_text"]
