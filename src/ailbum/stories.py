from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone

from ailbum.models import StoryRecord


@dataclass(slots=True)
class StoryPhoto:
    photo_id: str
    taken_at: str | None
    gps_latitude: float | None = None
    gps_longitude: float | None = None
    people: frozenset[str] = field(default_factory=frozenset)
    scenes: tuple[tuple[str, float], ...] = ()
    objects: tuple[tuple[str, float], ...] = ()
    quality: float = 0.0
    is_blurry: bool = False


_SCENE_TITLES = {
    "food": "За столом",
    "party": "Праздник",
    "ceremony": "Церемония",
    "performance": "Выступление",
    "portrait_session": "Фотосессия",
    "swimming": "Купание",
    "restaurant": "В ресторане",
    "sightseeing": "Осмотр достопримечательностей",
    "hotel": "Отдых в отеле",
    "beach": "У моря",
    "mountains": "В горах",
    "nature": "На природе",
    "city": "Городская прогулка",
    "transport": "В дороге",
    "architecture": "Архитектура",
    "night": "Вечер",
    "indoor": "В помещении",
}
_OBJECT_TITLES = {
    "animal": "С животными",
    "food": "За столом",
    "vehicle": "В дороге",
    "people": "Встреча",
}
_INFORMATIVE_SCENES = frozenset(_SCENE_TITLES) - {"indoor", "night"}
STORY_ALGORITHM_VERSION = 2


def detect_stories(
    photos: list[StoryPhoto],
    *,
    gap_minutes: int = 120,
    continuity_minutes: int = 360,
    max_duration_hours: int = 12,
    semantic_break_minutes: int = 30,
) -> list[StoryRecord]:
    """Split a chronological photo stream into deterministic narrative events.

    Time is the primary signal. Nearby GPS positions, recurring people and useful
    scene labels may bridge a longer pause; a large geographic jump forces a split.
    The implementation intentionally has no network or language-model dependency.
    """
    if gap_minutes < 1:
        raise ValueError("Story gap must be at least one minute")
    if continuity_minutes < gap_minutes:
        raise ValueError("Story continuity window must not be shorter than the gap")
    if max_duration_hours < 1:
        raise ValueError("Story maximum duration must be at least one hour")
    if semantic_break_minutes < 1:
        raise ValueError("Story semantic break must be at least one minute")
    if not photos:
        return []

    parsed = {photo.photo_id: _parse_time(photo.taken_at) for photo in photos}
    ordered = sorted(
        enumerate(photos),
        key=lambda item: (
            parsed[item[1].photo_id] is None,
            _time_key(parsed[item[1].photo_id]),
            item[0],
        ),
    )
    groups: list[list[StoryPhoto]] = []
    for _, photo in ordered:
        if not groups or not _continues_story(
            groups[-1],
            photo,
            parsed,
            gap_minutes=gap_minutes,
            continuity_minutes=continuity_minutes,
            max_duration_hours=max_duration_hours,
            semantic_break_minutes=semantic_break_minutes,
        ):
            groups.append([photo])
        else:
            groups[-1].append(photo)

    stories: list[StoryRecord] = []
    for story_id, members in enumerate(groups, start=1):
        times = [parsed[item.photo_id] for item in members if parsed[item.photo_id] is not None]
        scenes = _rank_labels(members, "scenes")
        objects = _rank_labels(members, "objects")
        representative = max(
            enumerate(members),
            key=lambda item: (not item[1].is_blurry, item[1].quality, -item[0]),
        )[1]
        stories.append(
            StoryRecord(
                story_id=story_id,
                title=_story_title(story_id, members, scenes, objects),
                photo_ids=[item.photo_id for item in members],
                started_at=_format_time(min(times)) if times else None,
                ended_at=_format_time(max(times)) if times else None,
                representative_photo_id=representative.photo_id,
                scene_labels=scenes,
                object_labels=objects,
            )
        )
    return stories


def _continues_story(
    members: list[StoryPhoto],
    photo: StoryPhoto,
    parsed: dict[str, datetime | None],
    *,
    gap_minutes: int,
    continuity_minutes: int,
    max_duration_hours: int,
    semantic_break_minutes: int,
) -> bool:
    previous = members[-1]
    current_time = parsed[photo.photo_id]
    previous_time = parsed[previous.photo_id]
    first_time = parsed[members[0].photo_id]
    if current_time is None or previous_time is None or first_time is None:
        return False

    gap = (current_time - previous_time).total_seconds() / 60
    duration = (current_time - first_time).total_seconds() / 3600
    if gap < 0 or gap > continuity_minutes or duration > max_duration_hours:
        return False

    distance = _distance_km(previous, photo)
    if distance is not None and distance > 25 and gap > 15:
        return False
    if gap >= semantic_break_minutes and _semantic_scene_changed(members, photo):
        return False
    if gap <= gap_minutes:
        return True

    shared_people = bool(previous.people & photo.people)
    previous_scenes = {label for label, _ in previous.scenes}
    current_scenes = {label for label, _ in photo.scenes}
    shared_scene = bool(previous_scenes & current_scenes & _INFORMATIVE_SCENES)
    if distance is not None and distance <= 3:
        return True
    if shared_people and gap <= min(continuity_minutes, gap_minutes * 2):
        return True
    return shared_people and shared_scene or shared_scene and gap <= gap_minutes * 1.5


def _semantic_scene_changed(members: list[StoryPhoto], photo: StoryPhoto) -> bool:
    current = _strong_informative_scenes([photo])
    previous = _strong_informative_scenes(members[-5:])
    return bool(current and previous and current.isdisjoint(previous))


def _strong_informative_scenes(photos: list[StoryPhoto]) -> set[str]:
    scores: defaultdict[str, float] = defaultdict(float)
    observations: defaultdict[str, int] = defaultdict(int)
    for photo in photos:
        for label, confidence in photo.scenes:
            if label in _INFORMATIVE_SCENES and confidence >= 0.35:
                scores[label] += confidence
                observations[label] += 1
    if not scores:
        return set()
    best = max(scores.values())
    return {
        label
        for label, score in scores.items()
        if score >= max(0.45, best * 0.72) and observations[label] >= 1
    }


def _rank_labels(photos: list[StoryPhoto], attribute: str) -> list[str]:
    scores: defaultdict[str, float] = defaultdict(float)
    for photo in photos:
        for label, confidence in getattr(photo, attribute):
            scores[label] += max(0.0, confidence)
    return [label for label, _ in sorted(scores.items(), key=lambda item: (-item[1], item[0]))]


def _story_title(
    story_id: int,
    photos: list[StoryPhoto],
    scenes: list[str],
    objects: list[str],
) -> str:
    scene_set = set(scenes)
    object_set = set(objects)
    if "beach" in scene_set and "night" in scene_set:
        if (
            "portrait_session" in scene_set
            or len(photos) >= 3
            and ("people" in object_set or any(photo.people for photo in photos))
        ):
            return "Ночная фотосессия на пляже"
        return "Ночной пляж"
    if "city" in scene_set and "night" in scene_set:
        return "Вечерняя прогулка по городу"
    if "mountains" in scene_set and "nature" in scene_set:
        return "Прогулка в горах"
    for label in scenes:
        if label in _SCENE_TITLES and label not in {"indoor", "night"}:
            return _SCENE_TITLES[label]
    for label in objects:
        if label in _OBJECT_TITLES and label != "people":
            return _OBJECT_TITLES[label]
    if any(photo.people for photo in photos) or "people" in objects:
        return "Совместный отдых"
    for label in scenes:
        if label in _SCENE_TITLES:
            return _SCENE_TITLES[label]
    return f"Сюжет без названия {story_id}"


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed


def _time_key(value: datetime | None) -> tuple[int, int, int, int, int, int, int]:
    if value is None:
        return (9999, 12, 31, 23, 59, 59, 999999)
    return (
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
        value.microsecond,
    )


def _format_time(value: datetime) -> str:
    return value.isoformat()


def _distance_km(left: StoryPhoto, right: StoryPhoto) -> float | None:
    if (
        left.gps_latitude is None
        or left.gps_longitude is None
        or right.gps_latitude is None
        or right.gps_longitude is None
    ):
        return None
    latitude_1 = math.radians(left.gps_latitude)
    latitude_2 = math.radians(right.gps_latitude)
    latitude_delta = latitude_2 - latitude_1
    longitude_delta = math.radians(right.gps_longitude - left.gps_longitude)
    value = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(latitude_1) * math.cos(latitude_2) * math.sin(longitude_delta / 2) ** 2
    )
    return 6371.0 * 2 * math.asin(min(1.0, math.sqrt(value)))
