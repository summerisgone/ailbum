from __future__ import annotations

import itertools
import json
import math
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from ailbum.database import connect
from ailbum.layout import preferences
from ailbum.layout.composer import MAX_CELLS, SELECTED_BONUS, best_variants
from ailbum.layout.crop import evaluate_crop, solve_crop
from ailbum.layout.facts import load_pool
from ailbum.layout.store import load_layout
from ailbum.layout.templates import format_for, templates_for
from ailbum.layout.types import Cell, LayoutParams, Rect

ALTERNATIVES_LIMIT = 24
UNKNOWN_WISH = "Пожелание не распознано: укажите лица, крупные планы или пейзажи"
ASPECT_TOLERANCE = 0.01
RANGE_EPS = 1e-6


def alternatives(database: Path, spread_id: int, cell_index: int) -> list[dict]:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        cell = _cell(spread, cell_index)
        pool = _pool(connection, spread["run_id"])
        scoped = [p for p in pool.values() if p.story_id in spread["story_ids"]]
        placed = _placed(connection, spread["layout_id"])
        row = _placements(connection, spread_id).get(cell_index)
        unit = pool[row["image_id"]].unit_key if row and row["image_id"] in pool else None
        found = [_candidate(p, cell, placed, unit) for p in scoped or pool.values()]
    found.sort(key=lambda item: (
        -(item["fit"] + (SELECTED_BONUS if item["in_selection"] else 0.0)), item["image_id"]))
    return found[:ALTERNATIVES_LIMIT]


def similar(database: Path, spread_id: int, cell_index: int) -> list[dict]:
    """The placed photo and its similar siblings, in shooting order."""
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        cell = _cell(spread, cell_index)
        row = _placements(connection, spread_id).get(cell_index)
        if row is None:
            raise ValueError(f"В ячейке {cell_index} нет фото")
        pool = _pool(connection, spread["run_id"])
        photo = _photo(pool, row["image_id"])
        placed = _placed(connection, spread["layout_id"])
        members = sorted(
            (p for p in pool.values() if p.unit_key == photo.unit_key),
            key=lambda p: (p.taken_at is None, p.taken_at or "", p.image_id),
        )
        return [_candidate(p, cell, placed, photo.unit_key) for p in members]


def variants(database: Path, spread_id: int) -> list[dict]:
    """Other templates for the same photos, then with one free photo more and one less."""
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        pool = _pool(connection, spread["run_id"])
        current = _placements(connection, spread_id)
        photos = [_photo(pool, current[index]["image_id"]) for index in sorted(current)]
        sets = [photos]
        free = _free(connection, spread, pool)
        if free and len(photos) < MAX_CELLS:
            sets.append([*photos, max(free, key=lambda p: (p.rank, -p.image_id))])
        if len(photos) > 1:
            weakest = min(photos, key=lambda p: (p.rank, -p.image_id))
            sets.append([p for p in photos if p is not weakest])
        fmt = format_for(spread["orientation"])
        templates = {t.id: t for t in templates_for(spread["orientation"])}
        found = []
        for photo_set in sets:
            params = LayoutParams(spread["orientation"], 1, len(photo_set), len(photo_set))
            for draft in best_variants(photo_set, params, limit=len(templates)):
                if photo_set is photos and draft.template_id == spread["template_id"]:
                    continue
                found.append(_variant(draft, templates[draft.template_id], fmt))
        return found


def apply_variant(
    database: Path, spread_id: int, template_id: str, image_ids: list[int]
) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        pool = _pool(connection, spread["run_id"])
        ids = list(dict.fromkeys(int(i) for i in image_ids))
        if not 1 <= len(ids) <= MAX_CELLS:
            raise ValueError(f"На развороте может быть от 1 до {MAX_CELLS} фото")
        photos = [_photo(pool, i) for i in ids]
        busy = {i for i, where in _placed(connection, spread["layout_id"]).items()
                if where["spread_id"] != spread_id}
        if busy & set(ids):
            raise ValueError("Кадр уже стоит на другом развороте")
        params = LayoutParams(spread["orientation"], 1, len(photos), len(photos))
        draft = next((d for d in best_variants(photos, params, limit=99)
                      if d.template_id == template_id), None)
        if draft is None:
            raise ValueError(f"Шаблон {template_id} не подходит для {len(photos)} фото")
        _write_draft(connection, spread, draft, pool)
        return _finish(connection, spread)


def parse_prompt(prompt: str) -> dict:
    weights = preferences.parse(prompt)
    return {"weights": weights, "labels": preferences.describe(weights)}


def set_photo(database: Path, spread_id: int, cell_index: int, image_id: int) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        _cell(spread, cell_index)
        pool = _pool(connection, spread["run_id"])
        if image_id not in pool:
            raise ValueError(f"Кадр {image_id} недоступен для раскладки")
        holder = connection.execute(
            "SELECT p.spread_id, p.cell_index FROM layout_placements p"
            " JOIN layout_spreads s ON s.id = p.spread_id"
            " WHERE s.layout_id = ? AND p.image_id = ?",
            (spread["layout_id"], image_id),
        ).fetchone()
        if holder is None:
            _place(connection, spread, cell_index, pool[image_id], pool)
        elif (holder["spread_id"], holder["cell_index"]) != (spread_id, cell_index):
            _swap(connection, spread, cell_index, _spread(connection, holder["spread_id"]),
                  holder["cell_index"], pool)
        return _finish(connection, spread)


def swap_cells(database: Path, spread_id: int, cell_a: int, cell_b: int) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        _cell(spread, cell_a)
        _cell(spread, cell_b)
        if cell_a != cell_b:
            _swap(connection, spread, cell_a, spread, cell_b,
                  _pool(connection, spread["run_id"]))
        return _finish(connection, spread)


def set_template(database: Path, spread_id: int, template_id: str) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        template = next(
            (t for t in templates_for(spread["orientation"]) if t.id == template_id), None)
        if template is None:
            raise ValueError(f"Неизвестный шаблон: {template_id}")
        current = _placements(connection, spread_id)
        if template.photo_count != len(current):
            raise ValueError(
                f"Шаблон {template_id} рассчитан на {template.photo_count} фото, "
                f"в развороте {len(current)}")
        pool = _pool(connection, spread["run_id"])
        photos = [_photo(pool, current[index]["image_id"]) for index in sorted(current)]
        results = {
            (p.image_id, c.index): solve_crop(p.aspect, p.regions, c)
            for p in photos for c in template.cells
        }
        areas = [c.rect.w * c.rect.h for c in template.cells]

        def total(order: tuple[int, ...]) -> float:
            return sum(areas[i] * results[(photos[order[i]].image_id, i)].fit
                       for i in range(len(photos)))

        # Ties keep the earliest permutation, so the result is deterministic.
        best = max(itertools.permutations(range(len(photos))), key=total)
        connection.execute(
            "UPDATE layout_spreads SET template_id = ? WHERE id = ?", (template_id, spread_id))
        spread = _spread(connection, spread_id)
        for index, photo_pos in enumerate(best):
            photo = photos[photo_pos]
            _place(connection, spread, index, photo, pool, results[(photo.image_id, index)])
        return _finish(connection, spread)


def set_crop(database: Path, spread_id: int, cell_index: int, crop: dict) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        cell = _cell(spread, cell_index)
        row = _placements(connection, spread_id).get(cell_index)
        if row is None:
            raise ValueError(f"В ячейке {cell_index} нет фото")
        photo = _photo(_pool(connection, spread["run_id"]), row["image_id"])
        rect = _validated_window(crop, photo.aspect, cell)
        result = evaluate_crop(rect, photo.aspect, photo.regions, cell)
        _write(connection, spread_id, cell_index, row["image_id"], result,
               row["replaced_image_id"])
        return _finish(connection, spread)


def recompose_spread(database: Path, spread_id: int, prompt: str = "") -> dict:
    """Without a wish the same photos get the best template; a wish re-picks them."""
    weights = preferences.parse(prompt)
    if prompt.strip() and not weights:
        raise ValueError(UNKNOWN_WISH)
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        current = _placements(connection, spread_id)
        pool = _pool(connection, spread["run_id"])
        photos = [_photo(pool, current[index]["image_id"]) for index in sorted(current)]
        if weights:
            photos = _pick(photos, _free(connection, spread, pool), weights)
        params = LayoutParams(spread["orientation"], 1, len(photos), len(photos))
        variants = best_variants(photos, params, limit=1)
        if not variants:
            raise ValueError("Не удалось перекомпоновать разворот")
        _write_draft(connection, spread, variants[0], pool)
        return _finish(connection, spread)


def _pick(photos: list, free: list, weights: dict[str, float]) -> list:
    """Same count of units, best member of each by rank adjusted to the wish."""
    best: dict[str, object] = {}
    for photo in preferences.apply([*photos, *free], weights):
        held = best.get(photo.unit_key)
        if held is None or (photo.rank, -photo.image_id) > (held.rank, -held.image_id):
            best[photo.unit_key] = photo
    ranked = sorted(best.values(), key=lambda p: (-p.rank, p.image_id))
    return ranked[: len(photos)]


def _free(connection: sqlite3.Connection, spread: dict, pool: dict) -> list:
    """Pool photos of the spread's stories whose similar group is not on the layout yet."""
    used = {pool[i].unit_key for i in _placed(connection, spread["layout_id"]) if i in pool}
    return [p for p in pool.values()
            if p.story_id in spread["story_ids"] and p.unit_key not in used]


def _placed(connection: sqlite3.Connection, layout_id: int) -> dict[int, dict]:
    rows = connection.execute(
        "SELECT p.image_id, p.spread_id, p.cell_index, s.position FROM layout_placements p"
        " JOIN layout_spreads s ON s.id = p.spread_id WHERE s.layout_id = ?",
        (layout_id,),
    )
    return {
        int(row["image_id"]): {
            "spread_id": int(row["spread_id"]),
            "position": int(row["position"]),
            "cell_index": int(row["cell_index"]),
        }
        for row in rows
    }


def _candidate(photo, cell: Cell, placed: dict, unit_key: str | None) -> dict:
    result = solve_crop(photo.aspect, photo.regions, cell)
    return {
        "image_id": photo.image_id,
        "fit": result.fit,
        "warnings": list(result.violations),
        "in_selection": bool(photo.selected),
        "placed": placed.get(photo.image_id),
        "similar": unit_key is not None and photo.unit_key == unit_key,
    }


def _variant(draft, template, fmt) -> dict:
    cells = {c.index: c for c in template.cells}
    return {
        "template_id": draft.template_id,
        "score": draft.score,
        "image_ids": sorted(p.image_id for p in draft.placements),
        "cells": [
            {
                "index": p.cell_index,
                "x": cells[p.cell_index].rect.x / fmt.spread_w_mm,
                "y": cells[p.cell_index].rect.y / fmt.spread_h_mm,
                "w": cells[p.cell_index].rect.w / fmt.spread_w_mm,
                "h": cells[p.cell_index].rect.h / fmt.spread_h_mm,
                "image_id": p.image_id,
                "crop": _rect_dict(getattr(p.crop, "rect", p.crop)),
            }
            for p in sorted(draft.placements, key=lambda item: item.cell_index)
        ],
    }


def _rect_dict(rect: Rect) -> dict:
    return {"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}


def _write_draft(connection: sqlite3.Connection, spread: dict, draft, pool: dict) -> None:
    """Replace the spread's template and photos; dropped photos go to the unplaced list."""
    spread_id = spread["id"]
    before = {row["image_id"] for row in _placements(connection, spread_id).values()}
    connection.execute(
        "UPDATE layout_spreads SET template_id = ?, warnings_json = ?,"
        " assistant_reason = NULL WHERE id = ?",
        (draft.template_id, json.dumps(list(draft.warnings)), spread_id),
    )
    connection.execute("DELETE FROM layout_placements WHERE spread_id = ?", (spread_id,))
    for item in draft.placements:
        rect = getattr(item.crop, "rect", item.crop)
        photo = pool.get(item.image_id)
        replaced = _replaced(photo, pool) if photo is not None else item.replaced_image_id
        connection.execute(
            "INSERT INTO layout_placements (spread_id, cell_index, image_id, crop_x, crop_y,"
            " crop_w, crop_h, fit, warnings_json, replaced_image_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (spread_id, item.cell_index, item.image_id, rect.x, rect.y, rect.w, rect.h,
             item.fit, json.dumps(list(item.warnings)), replaced),
        )
    placed = _placed(connection, spread["layout_id"])
    row = connection.execute(
        "SELECT unplaced_json FROM layouts WHERE id = ?", (spread["layout_id"],)).fetchone()
    unplaced = [u for u in json.loads(row["unplaced_json"]) if u["image_id"] not in placed]
    known = {u["image_id"] for u in unplaced}
    unplaced += [{"image_id": i, "reason": "removed"}
                 for i in sorted(before) if i not in placed and i not in known]
    connection.execute(
        "UPDATE layouts SET unplaced_json = ? WHERE id = ?",
        (json.dumps(unplaced, ensure_ascii=False), spread["layout_id"]),
    )


def _spread(connection: sqlite3.Connection, spread_id: int) -> dict:
    row = connection.execute(
        "SELECT s.id, s.layout_id, s.template_id, s.story_ids_json, l.run_id, l.orientation"
        " FROM layout_spreads s JOIN layouts l ON l.id = s.layout_id WHERE s.id = ?",
        (spread_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"Разворот {spread_id} не найден")
    spread = dict(row)
    spread["story_ids"] = set(json.loads(spread.pop("story_ids_json")))
    template = next(
        (t for t in templates_for(spread["orientation"]) if t.id == spread["template_id"]), None)
    if template is None:
        raise ValueError(f"Неизвестный шаблон: {spread['template_id']}")
    spread["cells"] = {c.index: c for c in template.cells}
    return spread


def _cell(spread: dict, cell_index: int) -> Cell:
    try:
        return spread["cells"][cell_index]
    except KeyError:
        raise ValueError(f"Ячейка {cell_index} не найдена") from None


def _placements(connection: sqlite3.Connection, spread_id: int) -> dict[int, sqlite3.Row]:
    rows = connection.execute(
        "SELECT * FROM layout_placements WHERE spread_id = ?", (spread_id,)).fetchall()
    return {row["cell_index"]: row for row in rows}


def _pool(connection: sqlite3.Connection, run_id: str) -> dict:
    # detector=None reads cached scans only, so edits never rerun or drop them.
    return {p.image_id: p for p in load_pool(connection, run_id, None)}


def _photo(pool: dict, image_id: int):
    try:
        return pool[image_id]
    except KeyError:
        raise ValueError(f"Кадр {image_id} недоступен для раскладки") from None


def _replaced(photo, pool: dict) -> int | None:
    if photo.selected:
        return None
    siblings = [p.image_id for p in pool.values()
                if p.unit_key == photo.unit_key and p.selected]
    return min(siblings) if siblings else None


def _place(connection, spread: dict, cell_index: int, photo, pool: dict, result=None) -> None:
    result = result or solve_crop(photo.aspect, photo.regions, _cell(spread, cell_index))
    _write(connection, spread["id"], cell_index, photo.image_id, result, _replaced(photo, pool))


def _swap(connection, spread_a: dict, cell_a: int, spread_b: dict, cell_b: int, pool) -> None:
    row_a = _placements(connection, spread_a["id"]).get(cell_a)
    row_b = _placements(connection, spread_b["id"]).get(cell_b)
    if row_a is None or row_b is None:
        raise ValueError("В ячейке нет фото")
    photo_a = _photo(pool, row_a["image_id"])
    photo_b = _photo(pool, row_b["image_id"])
    _place(connection, spread_a, cell_a, photo_b, pool)
    _place(connection, spread_b, cell_b, photo_a, pool)


def _write(connection, spread_id, cell_index, image_id, result, replaced) -> None:
    rect = result.rect
    connection.execute(
        "UPDATE layout_placements SET image_id = ?, crop_x = ?, crop_y = ?, crop_w = ?,"
        " crop_h = ?, fit = ?, warnings_json = ?, replaced_image_id = ?"
        " WHERE spread_id = ? AND cell_index = ?",
        (image_id, rect.x, rect.y, rect.w, rect.h, result.fit,
         json.dumps(list(result.violations)), replaced, spread_id, cell_index),
    )


def _validated_window(crop: dict, photo_aspect: float, cell: Cell) -> Rect:
    try:
        x, y, w, h = (float(crop[key]) for key in ("x", "y", "w", "h"))
    except (KeyError, TypeError, ValueError):
        raise ValueError("Кроп должен содержать числа x, y, w, h") from None
    if not all(math.isfinite(v) for v in (x, y, w, h)):
        raise ValueError("Кроп должен содержать конечные числа")
    if w <= 0 or h <= 0 or x < -RANGE_EPS or y < -RANGE_EPS:
        raise ValueError("Кроп выходит за пределы кадра")
    if x + w > 1 + RANGE_EPS or y + h > 1 + RANGE_EPS:
        raise ValueError("Кроп выходит за пределы кадра")
    window_aspect = w * photo_aspect / h
    cell_aspect = cell.rect.w / cell.rect.h
    if abs(window_aspect / cell_aspect - 1) > ASPECT_TOLERANCE:
        raise ValueError("Пропорции кропа не совпадают с ячейкой")
    return Rect(max(x, 0.0), max(y, 0.0), w, h)


def _finish(connection: sqlite3.Connection, spread: dict) -> dict:
    connection.execute(
        "UPDATE layouts SET updated_at = ? WHERE id = ?",
        (datetime.now(timezone.utc).isoformat(timespec="seconds"), spread["layout_id"]),
    )
    layout = load_layout(connection, spread["run_id"])
    assert layout is not None
    return layout
