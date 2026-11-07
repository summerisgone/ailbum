from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import replace

from ailbum.layout.facts import PhotoFacts

# Free-text wishes map onto three axes the picker can measure from protected regions.
AXES = ("faces", "closeups", "landscapes")
LABELS = {
    "faces": ("больше лиц", "меньше лиц"),
    "closeups": ("больше крупных планов", "меньше крупных планов"),
    "landscapes": ("больше пейзажей", "меньше пейзажей"),
}
STRENGTH = 0.5
CLOSEUP_AREA = 0.15
MAX_PROMPT = 500

_PATTERNS = {
    "faces": re.compile(r"лиц|люд|человек|портрет|семь|дет(?!ал)|друз|групп"),
    "closeups": re.compile(r"крупн|портрет|детал"),
    "landscapes": re.compile(
        r"пейзаж|природ|панорам|архитектур|город|море|моря|горы|гор\b|общ\w* план|вид(ы|ов)?\b"
    ),
}
_NEGATIVE = re.compile(r"(^|\s)(не|без|меньше|поменьше|убери\w*|исключ\w*|кроме|вместо)(\s|$)")
_CLAUSES = re.compile(r"[,.;:!?\n]+|\s+(?:а|но|зато)\s+")


def parse(prompt: str) -> dict[str, float]:
    """Axis weights in [-1, 1]; a clause with a negation word lowers what it names."""
    weights: dict[str, float] = {}
    for clause in _CLAUSES.split(prompt.lower()[:MAX_PROMPT]):
        sign = -1.0 if _NEGATIVE.search(clause) else 1.0
        for axis, pattern in _PATTERNS.items():
            if pattern.search(clause):
                weights[axis] = max(-1.0, min(1.0, weights.get(axis, 0.0) + sign))
    return {axis: value for axis, value in weights.items() if value}


def describe(weights: dict[str, float]) -> list[str]:
    return [LABELS[axis][0 if weights[axis] > 0 else 1] for axis in AXES if axis in weights]


def features(photo: PhotoFacts) -> dict[str, float]:
    faces = [r for r in photo.regions if r.kind == "face"]
    people = faces or [r for r in photo.regions if r.kind in ("person", "face_background")]
    largest = max((r.bbox.w * r.bbox.h for r in faces), default=0.0)
    return {
        "faces": 1.0 if faces else 0.5 if people else 0.0,
        "closeups": min(1.0, largest / CLOSEUP_AREA),
        "landscapes": 0.0 if people else 1.0,
    }


def apply(photos: Sequence[PhotoFacts], weights: dict[str, float]) -> list[PhotoFacts]:
    if not weights:
        return list(photos)
    adjusted = []
    for photo in photos:
        values = features(photo)
        bonus = STRENGTH * sum(weight * values[axis] for axis, weight in weights.items())
        adjusted.append(replace(photo, rank=photo.rank + bonus))
    return adjusted
