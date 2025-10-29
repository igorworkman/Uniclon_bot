from __future__ import annotations

import hashlib
import random
import threading
from pathlib import Path
from typing import Iterable, TypeVar

_T = TypeVar("_T")

_state = threading.local()


def _current_rng() -> random.Random:
    rng = getattr(_state, "rng", None)
    if rng is None:
        raise RuntimeError("Seed not initialized; call generate_seed() first")
    return rng


def generate_seed(base: str, index: int, salt: str = "uniclon") -> str:
    token = f"{Path(base).name}:{index}:{salt}".encode("utf-8")
    seed = hashlib.md5(token).hexdigest()
    _state.seed = seed
    _state.rng = random.Random(int(seed, 16))
    return seed


def seeded_uniform(a: float, b: float) -> float:
    return _current_rng().uniform(a, b)


def seeded_random_choice(options: Iterable[_T]) -> _T:
    population = list(options)
    if not population:
        raise ValueError("seeded_random_choice requires a non-empty iterable")
    return _current_rng().choice(population)


def current_rng() -> random.Random:
    return _current_rng()


__all__ = [
    "generate_seed",
    "seeded_uniform",
    "seeded_random_choice",
    "current_rng",
]
