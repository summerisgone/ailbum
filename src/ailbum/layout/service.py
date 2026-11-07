from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from typing import Any

from ailbum.database import connect
from ailbum.layout.allocation import StoryGroup, allocate_spreads
from ailbum.layout.assistant import LayoutAssistant
from ailbum.layout.composer import compose_group
from ailbum.layout.facts import load_pool
from ailbum.layout.store import load_layout, save_layout, selection_hash
from ailbum.layout.types import LayoutParams

Progress = Callable[[str, str, int | None, int | None], None]

DETECTOR_WARNING = (
    "Модель детектора объектов не найдена: защита областей только по лицам и saliency"
)
ASSISTANT_WARNING = "AI-редактор недоступен: использован выбор движка"


def preflight(database: Path, run_id: str, params: LayoutParams) -> dict[str, Any]:
    with connect(database) as connection:
        pool = load_pool(connection, run_id, None)
        groups, _ = _group_pool(connection, run_id, pool)
    return _summary(params, len(pool), groups)


def generate(
    database: Path,
    run_id: str,
    params: LayoutParams,
    models_dir: Path | None,
    progress: Progress | None = None,
) -> dict[str, Any]:
    report = progress or (lambda *_: None)
    warnings: list[str] = []
    with connect(database) as connection:
        detector = _open_detector(models_dir)
        if detector is None:
            warnings.append(DETECTOR_WARNING)
        report("Анализ объектов", "Анализ объектов", 0, None)
        pool = load_pool(
            connection,
            run_id,
            detector,
            lambda done, total: report("Анализ объектов", "Анализ объектов", done, total),
        )
        groups, members = _group_pool(connection, run_id, pool)
        summary = _summary(params, len(pool), groups)
        if summary["errors"]:
            raise ValueError("\n".join(summary["errors"]))
        warnings.extend(summary["warnings"])

        allocations = allocate_spreads(
            [entry["group"] for entry in groups],
            params.spread_count,
            params.min_photos,
            params.max_photos,
        )
        assistant, assistant_model = _open_assistant(connection, run_id, params)
        if params.assistant != "off" and assistant is None:
            warnings.append(ASSISTANT_WARNING)

        paths = _image_paths(connection, [photo.image_id for photo in pool])
        titles = {entry["story_id"]: entry["title"] for entry in groups}
        spreads: list[Any] = []
        unplaced: list[dict[str, Any]] = []
        total = len(allocations)
        cursor = 0
        for index, allocation in enumerate(allocations):
            report("Компоновка", "Компоновка", index, total)
            taken, cursor = _take_groups(groups, cursor, allocation, index == total - 1)
            photos = [photo for key in taken for photo in members[key]]
            composed = compose_group(photos, allocation, params)
            unplaced.extend(_unplaced_dict(item) for item in composed.unplaced)
            title = " + ".join(titles[key] for key in taken if titles.get(key))
            for spread in composed.spreads:
                spreads.append(
                    _refine(spread, params, assistant, paths, title, report)
                )
        report("Компоновка", "Компоновка", total, total)

        save_layout(
            connection,
            run_id,
            params,
            spreads,
            unplaced,
            warnings,
            selection_hash(connection, run_id),
            assistant_model if assistant is not None else None,
        )
        layout = load_layout(connection, run_id)
    return layout or {}


def _refine(
    spread: Any,
    params: LayoutParams,
    assistant: LayoutAssistant | None,
    paths: dict[int, str],
    title: str,
    report: Progress,
) -> Any:
    if assistant is None:
        return spread
    report("AI-редактор", "AI-редактор", None, None)
    try:
        variants = [spread, *spread.alternatives]
        if len(variants) < 2:
            return spread
        choice = assistant.choose(variants, paths, params.orientation, title)
    except Exception:  # noqa: BLE001 - the assistant must never break generation
        return spread
    if choice is None or not 0 <= choice.index < len(variants):
        return spread
    return replace(variants[choice.index], assistant_reason=choice.reason)


def _validate(params: LayoutParams, unit_count: int) -> list[str]:
    errors: list[str] = []
    if params.spread_count < 1:
        errors.append("Число разворотов должно быть не меньше 1")
    for value in (params.min_photos, params.max_photos):
        if not 1 <= value <= 6:
            errors.append("Число фото на коллаже должно быть от 1 до 6")
            break
    if params.min_photos > params.max_photos:
        errors.append("Минимум фото на коллаже не может быть больше максимума")
    if params.spread_count >= 1 and unit_count < params.spread_count:
        errors.append("Кадров меньше, чем разворотов")
    return errors


def _summary(params: LayoutParams, pool_count: int, groups: list[dict[str, Any]]) -> dict[str, Any]:
    unit_count = sum(entry["group"].unit_count for entry in groups)
    errors = _validate(params, unit_count)
    warnings: list[str] = []
    min_needed = max(params.spread_count, 0) * params.min_photos
    max_used = max(params.spread_count, 0) * params.max_photos
    allocation: list[dict[str, Any]] = []
    if not errors:
        titles = {entry["story_id"]: entry["title"] for entry in groups}
        for item in allocate_spreads(
            [entry["group"] for entry in groups],
            params.spread_count,
            params.min_photos,
            params.max_photos,
        ):
            allocation.append(
                {
                    "story_ids": list(item.story_ids),
                    "title": " + ".join(titles[s] for s in item.story_ids if titles.get(s)),
                    "spreads": item.spreads,
                    "units": item.unit_count,
                }
            )
            if item.merged:
                warnings.append("Сюжеты объединены на одном развороте")
        if unit_count < min_needed:
            warnings.append("Кадров меньше минимума: часть коллажей будет неполной")
        if unit_count > max_used:
            warnings.append("Часть кадров не поместится в раскладку")
    return {
        "pool_count": pool_count,
        "unit_count": unit_count,
        "story_count": len([entry for entry in groups if entry["story_id"] is not None]),
        "min_needed": min_needed,
        "max_used": max_used,
        "allocation": allocation,
        "errors": errors,
        "warnings": list(dict.fromkeys(warnings)),
    }


def _group_pool(
    connection: Any, run_id: str, pool: list[Any]
) -> tuple[list[dict[str, Any]], dict[int | None, list[Any]]]:
    """Units go to one story each; the story of the lowest selected image decides."""
    units: dict[str, list[Any]] = {}
    for photo in pool:
        units.setdefault(photo.unit_key, []).append(photo)
    members: dict[int | None, list[Any]] = {}
    unit_counts: dict[int | None, int] = {}
    for unit in units.values():
        lead = min(unit, key=lambda p: (not p.selected, p.image_id))
        members.setdefault(lead.story_id, []).extend(unit)
        unit_counts[lead.story_id] = unit_counts.get(lead.story_id, 0) + 1
    rows = {
        int(row["story_id"]): row
        for row in connection.execute(
            "SELECT story_id, title, started_at, ended_at FROM stories WHERE run_id = ?",
            (run_id,),
        )
    }
    keys = sorted(
        members,
        key=lambda k: (
            k is None,
            rows[k]["started_at"] is None if k in rows else True,
            rows[k]["started_at"] or "" if k in rows else "",
            k if k is not None else 0,
        ),
    )
    groups = []
    for key in keys:
        row = rows.get(key) if key is not None else None
        groups.append(
            {
                "story_id": key,
                "title": str(row["title"]) if row else "",
                "group": StoryGroup(
                    (key,) if key is not None else (),
                    unit_counts[key],
                    row["started_at"] if row else None,
                    row["ended_at"] if row else None,
                ),
            }
        )
    return groups, members


def _take_groups(
    groups: list[dict[str, Any]], cursor: int, allocation: Any, last: bool
) -> tuple[list[int | None], int]:
    remaining = set(allocation.story_ids)
    taken: list[int | None] = []
    while cursor < len(groups):
        key = groups[cursor]["story_id"]
        if key is None:
            if remaining or not (last or not allocation.story_ids):
                break
        elif key in remaining:
            remaining.discard(key)
        else:
            break
        taken.append(key)
        cursor += 1
    return taken, cursor


def _open_detector(models_dir: Path | None) -> Any:
    if models_dir is None:
        return None
    from ailbum.cv.objects import ObjectDetector

    if not ObjectDetector.available(models_dir):
        return None
    return ObjectDetector(models_dir)


def _open_assistant(
    connection: Any, run_id: str, params: LayoutParams
) -> tuple[LayoutAssistant | None, str | None]:
    if params.assistant == "off":
        return None, None
    row = connection.execute(
        "SELECT config_json FROM analysis_runs WHERE id = ?", (run_id,)
    ).fetchone()
    config = json.loads(row["config_json"]) if row else {}
    model = str(config.get("lmstudio_model", "qwen/qwen3-vl-2b"))
    assistant = LayoutAssistant(
        str(config.get("lmstudio_url", "http://127.0.0.1:1234/v1")), model
    )
    try:
        connected = assistant.connect()
    except Exception:  # noqa: BLE001 - the assistant must never break generation
        connected = False
    return (assistant, model) if connected else (None, None)


def _image_paths(connection: Any, image_ids: list[int]) -> dict[int, str]:
    paths: dict[int, str] = {}
    for start in range(0, len(image_ids), 500):
        chunk = image_ids[start : start + 500]
        marks = ",".join("?" * len(chunk))
        for row in connection.execute(
            f"SELECT id, path FROM images WHERE id IN ({marks})", chunk
        ):
            paths[int(row["id"])] = str(row["path"])
    return paths


def _unplaced_dict(item: Any) -> dict[str, Any]:
    if isinstance(item, dict):
        return item
    return {"image_id": item.image_id, "reason": item.reason}
