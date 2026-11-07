from __future__ import annotations

import hashlib
import json
import sqlite3
from collections.abc import Sequence
from typing import TYPE_CHECKING, Any

from ailbum.database import utc_now

if TYPE_CHECKING:
    from ailbum.layout.composer import SpreadDraft
    from ailbum.layout.types import LayoutParams


def selection_hash(connection: sqlite3.Connection, album_id: int) -> str:
    rows = connection.execute(
        "SELECT image_id FROM album_photos WHERE album_id = ? ORDER BY image_id", (album_id,)
    )
    payload = ",".join(str(row[0]) for row in rows)
    return hashlib.sha256(payload.encode("ascii")).hexdigest()


def album_run(connection: sqlite3.Connection, album_id: int) -> str:
    row = connection.execute("SELECT run_id FROM albums WHERE id = ?", (album_id,)).fetchone()
    if row is None:
        raise ValueError("Альбом не найден")
    if row[0] is None:
        raise ValueError("У альбома нет анализа")
    return str(row[0])


def require_draft(connection: sqlite3.Connection, album_id: int) -> None:
    row = connection.execute("SELECT status FROM albums WHERE id = ?", (album_id,)).fetchone()
    if row is None:
        raise ValueError("Альбом не найден")
    if row[0] != "draft":
        raise ValueError("Альбом заказан: изменения недоступны")


def save_layout(
    connection: sqlite3.Connection,
    album_id: int,
    run_id: str,
    params: LayoutParams,
    spreads: Sequence[SpreadDraft],
    unplaced: list[dict],
    warnings: list[str],
    selection_hash: str,
    assistant_model: str | None,
) -> int:
    # Children are removed explicitly so replacement does not depend on PRAGMA foreign_keys.
    old = [
        row[0] for row in connection.execute("SELECT id FROM layouts WHERE album_id = ?", (album_id,))
    ]
    for layout_id in old:
        spread_ids = [
            row[0]
            for row in connection.execute(
                "SELECT id FROM layout_spreads WHERE layout_id = ?", (layout_id,)
            )
        ]
        for spread_id in spread_ids:
            connection.execute("DELETE FROM layout_placements WHERE spread_id = ?", (spread_id,))
        connection.execute("DELETE FROM layout_spreads WHERE layout_id = ?", (layout_id,))
        connection.execute("DELETE FROM layouts WHERE id = ?", (layout_id,))
    now = utc_now()
    cursor = connection.execute(
        """
        INSERT INTO layouts (
            album_id, run_id, orientation, spread_count, min_photos, max_photos, selection_hash,
            assistant_model, unplaced_json, warnings_json, prompt, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            album_id,
            run_id,
            params.orientation,
            params.spread_count,
            params.min_photos,
            params.max_photos,
            selection_hash,
            assistant_model,
            _dumps(unplaced),
            _dumps(warnings),
            params.prompt,
            now,
            now,
        ),
    )
    layout_id = int(cursor.lastrowid)
    for position, spread in enumerate(spreads, start=1):
        spread_id = connection.execute(
            """
            INSERT INTO layout_spreads (
                layout_id, position, template_id, story_ids_json, warnings_json, assistant_reason
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                layout_id,
                position,
                spread.template_id,
                _dumps(list(spread.story_ids)),
                _dumps(list(spread.warnings)),
                spread.assistant_reason,
            ),
        ).lastrowid
        for placement in spread.placements:
            crop = placement.crop
            connection.execute(
                """
                INSERT INTO layout_placements (
                    spread_id, cell_index, image_id, crop_x, crop_y, crop_w, crop_h, fit,
                    warnings_json, replaced_image_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    spread_id,
                    placement.cell_index,
                    placement.image_id,
                    crop.x,
                    crop.y,
                    crop.w,
                    crop.h,
                    placement.fit,
                    _dumps(list(placement.warnings)),
                    placement.replaced_image_id,
                ),
            )
    return layout_id


def load_layout(connection: sqlite3.Connection, album_id: int) -> dict | None:
    from ailbum.layout.templates import format_for, templates_for

    layout = connection.execute("SELECT * FROM layouts WHERE album_id = ?", (album_id,)).fetchone()
    if layout is None:
        return None
    run_id = layout["run_id"]
    orientation = layout["orientation"]
    fmt = format_for(orientation)
    templates = {template.id: template for template in templates_for(orientation)}
    titles = {
        int(row[0]): str(row[1])
        for row in connection.execute(
            "SELECT story_id, title FROM stories WHERE run_id = ?", (run_id,)
        )
    }
    spreads: list[dict[str, Any]] = []
    spread_rows = connection.execute(
        "SELECT * FROM layout_spreads WHERE layout_id = ? ORDER BY position", (layout["id"],)
    ).fetchall()
    for spread in spread_rows:
        placements = {
            int(row["cell_index"]): row
            for row in connection.execute(
                "SELECT * FROM layout_placements WHERE spread_id = ?", (spread["id"],)
            )
        }
        template = templates.get(spread["template_id"])
        if template is None:
            raise ValueError(f"Неизвестный шаблон: {spread['template_id']}")
        story_ids = json.loads(spread["story_ids_json"])
        cells = []
        for cell in sorted(template.cells, key=lambda item: item.index):
            row = placements.get(cell.index)
            cells.append(
                {
                    "index": cell.index,
                    "x": _fraction(cell.rect.x, fmt.spread_w_mm),
                    "y": _fraction(cell.rect.y, fmt.spread_h_mm),
                    "w": _fraction(cell.rect.w, fmt.spread_w_mm),
                    "h": _fraction(cell.rect.h, fmt.spread_h_mm),
                    "crosses_spine": cell.spine_band is not None,
                    "placement": None if row is None else _placement(row),
                }
            )
        spreads.append(
            {
                "id": int(spread["id"]),
                "position": int(spread["position"]),
                "template_id": spread["template_id"],
                "story_ids": story_ids,
                "story_title": " + ".join(titles[i] for i in story_ids if i in titles),
                "warnings": json.loads(spread["warnings_json"]),
                "assistant_reason": spread["assistant_reason"],
                "cells": cells,
            }
        )
    return {
        "id": int(layout["id"]),
        "album_id": album_id,
        "run_id": run_id,
        "prompt": layout["prompt"] or "",
        "orientation": orientation,
        "spread_count": int(layout["spread_count"]),
        "min_photos": int(layout["min_photos"]),
        "max_photos": int(layout["max_photos"]),
        "stale": layout["selection_hash"] != selection_hash(connection, album_id),
        "assistant_model": layout["assistant_model"],
        "warnings": json.loads(layout["warnings_json"]),
        "unplaced": json.loads(layout["unplaced_json"]),
        "format": {
            "spread_w_mm": fmt.spread_w_mm,
            "spread_h_mm": fmt.spread_h_mm,
            "bleed_mm": fmt.bleed_mm,
            "safe_mm": fmt.safe_mm,
        },
        "spreads": spreads,
    }


def _placement(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "image_id": int(row["image_id"]),
        "crop": {
            "x": row["crop_x"],
            "y": row["crop_y"],
            "w": row["crop_w"],
            "h": row["crop_h"],
        },
        "fit": row["fit"],
        "warnings": json.loads(row["warnings_json"]),
        "replaced_image_id": row["replaced_image_id"],
    }


def _fraction(value_mm: float, total_mm: float) -> float:
    return min(1.0, max(0.0, round(value_mm / total_mm, 5)))


def _dumps(value: object) -> str:
    return json.dumps(value, ensure_ascii=False)
