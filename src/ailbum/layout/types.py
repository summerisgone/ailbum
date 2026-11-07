from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Rect:
    x: float
    y: float
    w: float
    h: float


@dataclass(frozen=True, slots=True)
class Region:
    bbox: Rect
    weight: float
    hard: bool
    kind: str


@dataclass(frozen=True, slots=True)
class Cell:
    index: int
    rect: Rect
    safe: Rect
    spine_band: Rect | None


@dataclass(frozen=True, slots=True)
class CropResult:
    rect: Rect
    fit: float
    violations: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class LayoutParams:
    orientation: str
    spread_count: int
    min_photos: int
    max_photos: int
    assistant: str = "auto"
