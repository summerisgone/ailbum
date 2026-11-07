from __future__ import annotations

import itertools
import json
import math
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from ailbum.database import connect
from ailbum.layout.composer import best_variants
from ailbum.layout.crop import evaluate_crop, solve_crop
from ailbum.layout.facts import load_pool
from ailbum.layout.store import load_layout
from ailbum.layout.templates import templates_for
from ailbum.layout.types import Cell, LayoutParams, Rect

ALTERNATIVES_LIMIT = 24
ASPECT_TOLERANCE = 0.01
RANGE_EPS = 1e-6


def alternatives(database: Path, spread_id: int, cell_index: int) -> list[dict]:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        cell = _cell(spread, cell_index)
        found = []
        for photo in _pool(connection, spread["run_id"]).values():
            result = solve_crop(photo.aspect, photo.regions, cell)
            found.append({
                "image_id": photo.image_id,
                "fit": result.fit,
                "warnings": list(result.violations),
                "in_selection": bool(photo.selected),
            })
    found.sort(key=lambda item: (-item["fit"], item["image_id"]))
    return found[:ALTERNATIVES_LIMIT]


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


def recompose_spread(database: Path, spread_id: int) -> dict:
    with connect(database) as connection:
        spread = _spread(connection, spread_id)
        current = _placements(connection, spread_id)
        pool = _pool(connection, spread["run_id"])
        photos = [_photo(pool, current[index]["image_id"]) for index in sorted(current)]
        params = LayoutParams(spread["orientation"], 1, len(photos), len(photos))
        variants = best_variants(photos, params, limit=1)
        if not variants:
            raise ValueError("Не удалось перекомпоновать разворот")
        draft = variants[0]
        connection.execute(
            "UPDATE layout_spreads SET template_id = ?, warnings_json = ?,"
            " assistant_reason = NULL WHERE id = ?",
            (draft.template_id, json.dumps(list(draft.warnings)), spread_id),
        )
        connection.execute("DELETE FROM layout_placements WHERE spread_id = ?", (spread_id,))
        for item in draft.placements:
            rect = getattr(item.crop, "rect", item.crop)
            connection.execute(
                "INSERT INTO layout_placements (spread_id, cell_index, image_id, crop_x, crop_y,"
                " crop_w, crop_h, fit, warnings_json, replaced_image_id)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (spread_id, item.cell_index, item.image_id, rect.x, rect.y, rect.w, rect.h,
                 item.fit, json.dumps(list(item.warnings)), item.replaced_image_id),
            )
        return _finish(connection, spread)


def _spread(connection: sqlite3.Connection, spread_id: int) -> dict:
    row = connection.execute(
        "SELECT s.id, s.layout_id, s.template_id, l.run_id, l.orientation"
        " FROM layout_spreads s JOIN layouts l ON l.id = s.layout_id WHERE s.id = ?",
        (spread_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"Разворот {spread_id} не найден")
    spread = dict(row)
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
