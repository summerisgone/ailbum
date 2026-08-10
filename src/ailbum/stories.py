from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime

import numpy as np

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
    embedding: tuple[float, ...] | None = field(default=None, repr=False)
    quality: float = 0.0
    is_blurry: bool = False


@dataclass(slots=True)
class _Burst:
    photos: list[StoryPhoto]
    started_at: datetime
    ended_at: datetime
    vector: np.ndarray | None = None
    image_vector: np.ndarray | None = None
    semantic_vector: np.ndarray | None = None
    people: frozenset[str] = field(default_factory=frozenset)
    face_rate: float = 0.0


# These translations are a presentation fallback, not segmentation rules. The
# grouping algorithm below never branches on a label value.
_SCENE_TITLES = {
    "food": "За столом",
    "party": "Праздник",
    "ceremony": "Церемония",
    "performance": "Выступление",
    "portrait_session": "Фотосессия",
    "seaside_photo_session": "Фотосессия на берегу моря",
    "swimming": "Купание",
    "pool": "Фото у бассейна",
    "waterpark": "В аквапарке",
    "water_sports": "Водные развлечения",
    "restaurant": "В ресторане",
    "dinner": "Ужин",
    "hookah": "Отдых с кальяном",
    "sightseeing": "Осмотр достопримечательностей",
    "hotel": "Отдых в отеле",
    "hotel_lobby": "Фото в лобби отеля",
    "hotel_exterior": "Фото отеля снаружи",
    "beach": "У моря",
    "boat_trip": "Морская прогулка",
    "mountains": "В горах",
    "mountain_trip": "Поездка в горы",
    "evening_nature": "Вечерняя природа",
    "nature": "На природе",
    "city": "Городская прогулка",
    "transport": "В дороге",
    "architecture": "Архитектура",
    "diving": "Дайвинг",
    "night": "Вечер",
    "night_sky": "Ночное небо",
    "indoor": "В помещении",
}
_OBJECT_TITLES = {
    "animal": "С животными",
    "food": "За столом",
    "vehicle": "В дороге",
}
_GENERIC_SCENES = frozenset({"indoor", "night"})

# Model-level constants. They are deliberately label-agnostic and can be
# validated against any annotated library with ``ailbum evaluate-stories``.
_BURST_MINUTES = 1.0
_SEGMENT_PENALTY = 0.52
_TIME_WEIGHT = 0.0
_SCENE_VECTOR_WEIGHT = 0.10
_OBJECT_VECTOR_WEIGHT = 0.10
_PEOPLE_VECTOR_WEIGHT = 0.15
_FACE_PRESENCE_WEIGHT = 0.10
_CHANGE_POINT_THRESHOLD = 0.68
STORY_ALGORITHM_VERSION = 9


def detect_stories(
    photos: list[StoryPhoto],
    *,
    gap_minutes: int = 120,
    continuity_minutes: int = 360,
    max_duration_hours: int = 12,
    semantic_break_minutes: int = 30,
) -> list[StoryRecord]:
    """Group a photo stream into events using label-agnostic change points.

    CLIP image embeddings are the main signal. Scene/object distributions,
    recurring people, time and GPS are generic auxiliary features. Semantic
    label *names* are used only after grouping to create a fallback title.
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
    ordered = [
        photo
        for _, photo in sorted(
            enumerate(photos),
            key=lambda item: (
                parsed[item[1].photo_id] is None,
                _time_key(parsed[item[1].photo_id]),
                item[0],
            ),
        )
    ]
    timed = [photo for photo in ordered if parsed[photo.photo_id] is not None]
    untimed = [photo for photo in ordered if parsed[photo.photo_id] is None]

    if timed:
        bursts = _build_bursts(timed, parsed)
        _attach_feature_vectors(bursts)
        if any(burst.vector is not None for burst in bursts):
            burst_groups = _segment_bursts(
                bursts,
                continuity_minutes=continuity_minutes,
                max_duration_hours=max_duration_hours,
            )
            groups = [
                [photo for burst in group for photo in burst.photos]
                for group in burst_groups
            ]
        else:
            groups = _fallback_time_groups(
                timed,
                parsed,
                gap_minutes=gap_minutes,
                continuity_minutes=continuity_minutes,
                max_duration_hours=max_duration_hours,
            )
    else:
        groups = []
    groups.extend([[photo] for photo in untimed])
    return _story_records(groups, parsed)


def _build_bursts(
    photos: list[StoryPhoto], parsed: dict[str, datetime | None]
) -> list[_Burst]:
    bursts: list[_Burst] = []
    for photo in photos:
        taken_at = parsed[photo.photo_id]
        assert taken_at is not None
        if (
            not bursts
            or (taken_at - bursts[-1].ended_at).total_seconds() / 60 > _BURST_MINUTES
        ):
            bursts.append(_Burst([photo], taken_at, taken_at))
        else:
            bursts[-1].photos.append(photo)
            bursts[-1].ended_at = taken_at
    return bursts


def _attach_feature_vectors(bursts: list[_Burst]) -> None:
    scene_labels = sorted(
        {label for burst in bursts for photo in burst.photos for label, _ in photo.scenes}
    )
    object_labels = sorted(
        {label for burst in bursts for photo in burst.photos for label, _ in photo.objects}
    )
    people_labels = sorted(
        {person for burst in bursts for photo in burst.photos for person in photo.people}
    )
    scene_index = {label: index for index, label in enumerate(scene_labels)}
    object_index = {label: index for index, label in enumerate(object_labels)}
    people_index = {person: index for index, person in enumerate(people_labels)}
    embedding_dim = max(
        (
            len(photo.embedding)
            for burst in bursts
            for photo in burst.photos
            if photo.embedding
        ),
        default=0,
    )

    for burst in bursts:
        image_vectors = [
            np.asarray(photo.embedding, dtype=np.float64)
            for photo in burst.photos
            if photo.embedding and len(photo.embedding) == embedding_dim
        ]
        image_vector = _normalized(np.mean(image_vectors, axis=0)) if image_vectors else None
        scene_vector = np.zeros(len(scene_labels), dtype=np.float64)
        object_vector = np.zeros(len(object_labels), dtype=np.float64)
        people_vector = np.zeros(len(people_labels), dtype=np.float64)
        people: set[str] = set()
        for photo in burst.photos:
            for label, confidence in photo.scenes:
                scene_vector[scene_index[label]] += max(0.0, confidence)
            for label, confidence in photo.objects:
                object_vector[object_index[label]] += max(0.0, confidence)
            for person in photo.people:
                people_vector[people_index[person]] = 1.0
                people.add(person)
        divisor = max(1, len(burst.photos))
        scene_vector /= divisor
        object_vector /= divisor
        burst.people = frozenset(people)
        burst.face_rate = sum(bool(photo.people) for photo in burst.photos) / divisor
        burst.image_vector = image_vector
        burst.semantic_vector = _normalized(
            np.concatenate((_normalized(scene_vector), _normalized(object_vector)))
        )
        has_content = bool(image_vectors) or bool(np.any(scene_vector)) or bool(
            np.any(object_vector)
        ) or bool(people)
        if not has_content:
            continue
        components = [
            image_vector if image_vector is not None else np.zeros(embedding_dim),
            _SCENE_VECTOR_WEIGHT * _normalized(scene_vector),
            _OBJECT_VECTOR_WEIGHT * _normalized(object_vector),
            _PEOPLE_VECTOR_WEIGHT * _normalized(people_vector),
            np.asarray([_FACE_PRESENCE_WEIGHT * burst.face_rate]),
        ]
        burst.vector = _normalized(np.concatenate(components))

    # Failed/unsupported files remain in temporal order and inherit only the
    # closest content representation. They cannot invent a new story by being
    # unreadable.
    available = [index for index, burst in enumerate(bursts) if burst.vector is not None]
    for index, burst in enumerate(bursts):
        if burst.vector is None and available:
            closest = min(available, key=lambda candidate: abs(candidate - index))
            burst.vector = bursts[closest].vector.copy()  # type: ignore[union-attr]
            burst.image_vector = bursts[closest].image_vector
            burst.semantic_vector = bursts[closest].semantic_vector


def _segment_bursts(
    bursts: list[_Burst], *, continuity_minutes: int, max_duration_hours: int
) -> list[list[_Burst]]:
    if len(bursts) == 1:
        return [bursts]
    vectors = np.stack([burst.vector for burst in bursts])
    count = len(bursts)
    gaps = np.asarray(
        [
            (bursts[index].started_at - bursts[index - 1].ended_at).total_seconds()
            / 60
            for index in range(1, count)
        ],
        dtype=np.float64,
    )
    hard_boundaries = np.asarray(
        [
            gaps[index] > continuity_minutes
            or _large_geographic_jump(
                bursts[index], bursts[index + 1], float(gaps[index])
            )
            for index in range(count - 1)
        ],
        dtype=bool,
    )
    hard_prefix = np.concatenate(([0], np.cumsum(hard_boundaries.astype(np.int64))))
    time_costs = np.maximum(
        0.0, np.log1p(gaps) - math.log1p(_BURST_MINUTES)
    )
    time_prefix = np.concatenate(([0.0], np.cumsum(time_costs)))
    cumulative = np.vstack((np.zeros(vectors.shape[1]), np.cumsum(vectors, axis=0)))

    costs = np.full((count, count), np.inf, dtype=np.float64)
    for end in range(count):
        starts = np.arange(end + 1)
        sums = cumulative[end + 1] - cumulative[starts]
        dispersion = end - starts + 1 - np.linalg.norm(sums, axis=1)
        spans = np.asarray(
            [
                (bursts[end].ended_at - bursts[start].started_at).total_seconds()
                / 3600
                for start in starts
            ]
        )
        crosses_hard_boundary = hard_prefix[end] - hard_prefix[starts] > 0
        valid = (spans <= max_duration_hours) & ~crosses_hard_boundary
        costs[starts[valid], end] = dispersion[valid] + _TIME_WEIGHT * (
            time_prefix[end] - time_prefix[starts[valid]]
        )

    best = np.full(count + 1, np.inf, dtype=np.float64)
    previous = np.full(count + 1, -1, dtype=np.int64)
    best[0] = 0.0
    for end in range(1, count + 1):
        candidates = best[:end] + costs[:end, end - 1] + _SEGMENT_PENALTY
        start = int(np.argmin(candidates))
        best[end] = candidates[start]
        previous[end] = start

    ranges: list[tuple[int, int]] = []
    end = count
    while end > 0:
        start = int(previous[end])
        ranges.append((start, end))
        end = start
    ranges.reverse()
    ranges = _refine_change_points(ranges, bursts, gaps)
    return [bursts[start:end] for start, end in ranges]


def _refine_change_points(
    ranges: list[tuple[int, int]], bursts: list[_Burst], gaps: np.ndarray
) -> list[tuple[int, int]]:
    """Recover one strong hidden change in a compact global segment."""
    refined: list[tuple[int, int]] = []
    for start, end in ranges:
        # Long stories are intentionally allowed to be visually varied. A tiny
        # segment has too little context for reliable change-point repair.
        if not 4 <= end - start <= 8:
            refined.append((start, end))
            continue
        candidates: list[tuple[float, int]] = []
        for boundary in range(start + 1, end - 2):
            direct = _vector_distance(
                _visual_vector(bursts[boundary]),
                _visual_vector(bursts[boundary + 1]),
            )
            left = _mean_vector(
                [
                    _visual_vector(bursts[index])
                    for index in range(max(start, boundary - 2), boundary + 1)
                ]
            )
            right = _mean_vector(
                [
                    _visual_vector(bursts[index])
                    for index in range(boundary + 1, min(end, boundary + 4))
                ]
            )
            context = _vector_distance(left, right)
            semantic = _vector_distance(
                _mean_vector(
                    [
                        bursts[index].semantic_vector
                        for index in range(max(start, boundary - 2), boundary + 1)
                    ]
                ),
                _mean_vector(
                    [
                        bursts[index].semantic_vector
                        for index in range(boundary + 1, min(end, boundary + 4))
                    ]
                ),
            )
            face_change = abs(
                np.mean(
                    [
                        bursts[index].face_rate
                        for index in range(max(start, boundary - 2), boundary + 1)
                    ]
                )
                - np.mean(
                    [
                        bursts[index].face_rate
                        for index in range(boundary + 1, min(end, boundary + 4))
                    ]
                )
            )
            time_signal = math.log1p(gaps[boundary]) / math.log1p(360)
            score = (
                direct
                + context
                + 0.35 * time_signal
                + 0.25 * semantic
                + 0.20 * face_change
            )
            # A local repair is allowed only when both the adjacent bursts and
            # their surrounding windows change substantially. This rejects
            # isolated outliers and keeps long, visually varied trips intact.
            if (
                score >= _CHANGE_POINT_THRESHOLD
                and direct >= 0.30
                and context >= 0.23
            ):
                candidates.append((score, boundary + 1))
        if candidates:
            _, cut = max(candidates)
            refined.extend(((start, cut), (cut, end)))
        else:
            refined.append((start, end))
    return refined


def _fallback_time_groups(
    photos: list[StoryPhoto],
    parsed: dict[str, datetime | None],
    *,
    gap_minutes: int,
    continuity_minutes: int,
    max_duration_hours: int,
) -> list[list[StoryPhoto]]:
    groups: list[list[StoryPhoto]] = []
    for photo in photos:
        if not groups:
            groups.append([photo])
            continue
        previous = groups[-1][-1]
        current_time = parsed[photo.photo_id]
        previous_time = parsed[previous.photo_id]
        first_time = parsed[groups[-1][0].photo_id]
        assert current_time is not None and previous_time is not None and first_time is not None
        gap = (current_time - previous_time).total_seconds() / 60
        duration = (current_time - first_time).total_seconds() / 3600
        distance = _distance_km(previous, photo)
        shared_people = bool(previous.people & photo.people)
        continues = (
            0 <= gap <= gap_minutes
            and duration <= max_duration_hours
            and not (distance is not None and distance > 25 and gap > 15)
        ) or (
            gap_minutes < gap <= continuity_minutes
            and duration <= max_duration_hours
            and (shared_people or distance is not None and distance <= 3)
        )
        if continues:
            groups[-1].append(photo)
        else:
            groups.append([photo])
    return groups


def _story_records(
    groups: list[list[StoryPhoto]], parsed: dict[str, datetime | None]
) -> list[StoryRecord]:
    stories: list[StoryRecord] = []
    for story_id, members in enumerate(groups, start=1):
        times = [parsed[item.photo_id] for item in members if parsed[item.photo_id] is not None]
        scene_scores = _label_scores(members, "scenes")
        object_scores = _label_scores(members, "objects")
        scenes = _ranked_labels(scene_scores)
        objects = _ranked_labels(object_scores)
        representative = max(
            enumerate(members),
            key=lambda item: (not item[1].is_blurry, item[1].quality, -item[0]),
        )[1]
        stories.append(
            StoryRecord(
                story_id=story_id,
                title=_story_title(
                    story_id,
                    members,
                    scenes,
                    objects,
                    min(times) if times else None,
                    scene_scores,
                ),
                photo_ids=[item.photo_id for item in members],
                started_at=_format_time(min(times)) if times else None,
                ended_at=_format_time(max(times)) if times else None,
                representative_photo_id=representative.photo_id,
                scene_labels=scenes,
                object_labels=objects,
            )
        )
    return stories


def _label_scores(photos: list[StoryPhoto], attribute: str) -> dict[str, float]:
    scores: defaultdict[str, float] = defaultdict(float)
    for photo in photos:
        for label, confidence in getattr(photo, attribute):
            scores[label] += max(0.0, confidence)
    return dict(scores)


def _ranked_labels(scores: dict[str, float]) -> list[str]:
    return [label for label, _ in sorted(scores.items(), key=lambda item: (-item[1], item[0]))]


def _story_title(
    story_id: int,
    photos: list[StoryPhoto],
    scenes: list[str],
    objects: list[str],
    started_at: datetime | None,
    scene_scores: dict[str, float],
) -> str:
    del story_id
    informative = [
        label
        for label in scenes
        if label in _SCENE_TITLES and label not in _GENERIC_SCENES
    ]
    if informative:
        primary = informative[0]
        if (
            len(informative) > 1
            and scene_scores[informative[1]] >= scene_scores[primary] * 0.7
        ):
            secondary = _SCENE_TITLES[informative[1]]
            return f"{_SCENE_TITLES[primary]} · {secondary[:1].lower()}{secondary[1:]}"
        return _SCENE_TITLES[primary]
    for label in objects:
        if label in _OBJECT_TITLES:
            return _OBJECT_TITLES[label]
    if any(photo.people for photo in photos) or "people" in objects:
        return "Совместный отдых"
    for label in scenes:
        if label in _SCENE_TITLES:
            return _SCENE_TITLES[label]
    if started_at is not None:
        return f"Фотографии {started_at:%d.%m, %H:%M}"
    return "Фотографии без даты"


def _normalized(vector: np.ndarray) -> np.ndarray:
    vector = np.asarray(vector, dtype=np.float64).reshape(-1)
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 0 else vector


def _mean_vector(vectors: list[np.ndarray | None]) -> np.ndarray | None:
    present = [vector for vector in vectors if vector is not None and vector.size]
    return _normalized(np.sum(present, axis=0)) if present else None


def _vector_distance(left: np.ndarray | None, right: np.ndarray | None) -> float:
    if left is None and right is None:
        return 0.0
    if left is None or right is None:
        return 1.0
    left_norm = float(np.linalg.norm(left))
    right_norm = float(np.linalg.norm(right))
    if left_norm == 0 and right_norm == 0:
        return 0.0
    if left_norm == 0 or right_norm == 0:
        return 1.0
    return max(0.0, min(2.0, 1.0 - float(left @ right) / left_norm / right_norm))


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        parsed = parsed.replace(tzinfo=None)
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


def _distance_km_between_bursts(left: _Burst, right: _Burst) -> float | None:
    distances = [
        distance
        for left_photo in left.photos
        for right_photo in right.photos
        if (distance := _distance_km(left_photo, right_photo)) is not None
    ]
    return min(distances) if distances else None


def _large_geographic_jump(left: _Burst, right: _Burst, gap: float) -> bool:
    distance = _distance_km_between_bursts(left, right)
    return gap > 15 and distance is not None and distance > 25


def _visual_vector(burst: _Burst) -> np.ndarray | None:
    return burst.image_vector if burst.image_vector is not None else burst.vector


def _distance_km(left: StoryPhoto, right: StoryPhoto) -> float | None:
    if (
        left.gps_latitude is None
        or left.gps_longitude is None
        or right.gps_latitude is None
        or right.gps_longitude is None
        or left.gps_latitude == 0.0
        and left.gps_longitude == 0.0
        or right.gps_latitude == 0.0
        and right.gps_longitude == 0.0
    ):
        return None
    radius = 6371.0
    latitude_1 = math.radians(left.gps_latitude)
    latitude_2 = math.radians(right.gps_latitude)
    delta_latitude = latitude_2 - latitude_1
    delta_longitude = math.radians(right.gps_longitude - left.gps_longitude)
    haversine = (
        math.sin(delta_latitude / 2) ** 2
        + math.cos(latitude_1)
        * math.cos(latitude_2)
        * math.sin(delta_longitude / 2) ** 2
    )
    return radius * 2 * math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine))
