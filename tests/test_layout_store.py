from __future__ import annotations

import os
import sqlite3
import sys
import types
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from ailbum.database import connect
from ailbum.layout.store import load_layout, save_layout, selection_hash


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float


@dataclass
class FakeCell:
    index: int
    rect: Rect
    safe: Rect
    spine_band: Rect | None


@dataclass
class FakeTemplate:
    id: str
    cells: list[FakeCell]


@dataclass
class PlacementDraft:
    cell_index: int
    image_id: int
    crop: Rect
    fit: float
    warnings: list[str] = field(default_factory=list)
    replaced_image_id: int | None = None


@dataclass
class SpreadDraft:
    template_id: str
    story_ids: tuple[int, ...]
    placements: list[PlacementDraft]
    warnings: list[str] = field(default_factory=list)
    assistant_reason: str | None = None


@dataclass
class Params:
    orientation: str = "vertical"
    spread_count: int = 2
    min_photos: int = 3
    max_photos: int = 6
    assistant: str = "auto"


@pytest.fixture(autouse=True)
def templates(monkeypatch: pytest.MonkeyPatch) -> None:
    """Fake templates module by default; real one when SUPERLITE_REAL=1."""
    if os.environ.get("SUPERLITE_REAL") == "1":
        return
    fmt = types.SimpleNamespace(
        spread_w_mm=426.0, spread_h_mm=303.0, bleed_mm=3.0, safe_mm=3.0
    )
    cells = [
        FakeCell(0, Rect(0, 0, 213, 303), Rect(3, 3, 207, 297), None),
        FakeCell(1, Rect(213, 0, 213, 151.5), Rect(213, 3, 207, 145), Rect(205, 0, 16, 151.5)),
        FakeCell(2, Rect(213, 151.5, 213, 151.5), Rect(213, 151.5, 207, 148), None),
    ]
    module = types.ModuleType("ailbum.layout.templates")
    module.format_for = lambda orientation: fmt
    module.templates_for = lambda orientation, photo_count=None: [FakeTemplate("page_2h", cells)]
    monkeypatch.setitem(sys.modules, "ailbum.layout.templates", module)


def _seed(connection: sqlite3.Connection, run_id: str = "r") -> None:
    connection.execute(
        "INSERT INTO analysis_runs VALUES (?, 's', 'o', 't', 't', 'f', '{}', '{}', 'completed')",
        (run_id,),
    )
    for image_id in range(1, 11):
        connection.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
                file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,
                indexed_at)
            VALUES (?, ?, 'root', ?, ?, 'jpg', 1, 't', 'x', '{}', '{}', 't')
            """,
            (image_id, f"/p/{image_id}.jpg", f"{image_id}.jpg", f"{image_id}.jpg"),
        )
        connection.execute(
            "INSERT INTO photo_selections VALUES (?, ?, 't', ?)", (run_id, image_id, image_id)
        )
    for story_id, title in ((1, "Ужин"), (2, "Прогулка")):
        connection.execute(
            "INSERT INTO stories (run_id, story_id, title) VALUES (?, ?, ?)",
            (run_id, story_id, title),
        )


def _spread(story_ids: tuple[int, ...] = (1,), first: int = 7) -> SpreadDraft:
    return SpreadDraft(
        "page_2h",
        story_ids,
        [
            PlacementDraft(0, first, Rect(0.1, 0.0, 0.6, 1.0), 0.82),
            PlacementDraft(1, first + 1, Rect(0, 0, 1, 1), 0.5, ["face_cut"], 3),
            PlacementDraft(2, first + 2, Rect(0, 0, 1, 1), 0.9),
        ],
        ["underfilled"],
        "лучше читается",
    )


def _save(connection: sqlite3.Connection, spreads: list[SpreadDraft] | None = None) -> int:
    return save_layout(
        connection,
        "r",
        Params(),
        spreads if spreads is not None else [_spread()],
        [{"image_id": 9, "reason": "capacity"}],
        ["w"],
        selection_hash(connection, "r"),
        "model-x",
    )


@pytest.fixture
def conn(tmp_path: Path):
    with connect(tmp_path / "db.sqlite3") as connection:
        _seed(connection)
        yield connection


def test_load_missing_is_none(conn: sqlite3.Connection) -> None:
    assert load_layout(conn, "missing") is None
    assert load_layout(conn, "r") is None


def test_round_trip_matches_contract(conn: sqlite3.Connection) -> None:
    layout_id = _save(conn)
    layout = load_layout(conn, "r")
    assert layout is not None
    assert {
        "id", "run_id", "orientation", "spread_count", "min_photos", "max_photos", "stale",
        "assistant_model", "warnings", "unplaced", "format", "spreads",
    } <= set(layout)
    assert layout["id"] == layout_id
    assert layout["run_id"] == "r"
    assert layout["stale"] is False
    assert layout["assistant_model"] == "model-x"
    assert layout["warnings"] == ["w"]
    assert layout["unplaced"] == [{"image_id": 9, "reason": "capacity"}]
    assert layout["format"] == {
        "spread_w_mm": 426.0, "spread_h_mm": 303.0, "bleed_mm": 3.0, "safe_mm": 3.0
    }
    spread = layout["spreads"][0]
    assert {
        "id", "position", "template_id", "story_ids", "story_title", "warnings",
        "assistant_reason", "cells",
    } <= set(spread)
    assert spread["position"] == 1
    assert spread["story_ids"] == [1]
    assert spread["warnings"] == ["underfilled"]
    assert spread["assistant_reason"] == "лучше читается"
    cell = spread["cells"][0]
    assert {"index", "x", "y", "w", "h", "crosses_spine", "placement"} <= set(cell)
    assert cell["placement"] == {
        "image_id": 7,
        "crop": {"x": 0.1, "y": 0.0, "w": 0.6, "h": 1.0},
        "fit": 0.82,
        "warnings": [],
        "replaced_image_id": None,
    }
    assert spread["cells"][1]["placement"]["warnings"] == ["face_cut"]
    assert spread["cells"][1]["placement"]["replaced_image_id"] == 3
    assert layout["spreads"][0]["cells"][0]["placement"]["image_id"] == 7


def test_cell_fractions_from_template(conn: sqlite3.Connection) -> None:
    _save(conn)
    cells = load_layout(conn, "r")["spreads"][0]["cells"]
    assert (cells[0]["x"], cells[0]["y"], cells[0]["w"], cells[0]["h"]) == (0.0, 0.0, 0.5, 1.0)
    assert cells[1]["x"] == 0.5 and cells[1]["y"] == 0.0 and cells[1]["h"] == 0.5
    assert cells[2]["y"] == 0.5
    assert [c["crosses_spine"] for c in cells] == [False, True, False]
    for c in cells:
        assert 0.0 <= c["x"] and c["x"] + c["w"] <= 1.0
        assert 0.0 <= c["y"] and c["y"] + c["h"] <= 1.0


def test_story_title_joined_for_merged(conn: sqlite3.Connection) -> None:
    _save(conn, [_spread((1, 2))])
    spread = load_layout(conn, "r")["spreads"][0]
    assert spread["story_title"] == "Ужин + Прогулка"
    assert spread["story_ids"] == [1, 2]


def test_unknown_story_gives_empty_title(conn: sqlite3.Connection) -> None:
    _save(conn, [_spread((99,))])
    assert load_layout(conn, "r")["spreads"][0]["story_title"] == ""


def test_save_replaces_previous_layout(conn: sqlite3.Connection) -> None:
    _save(conn, [_spread(), _spread((2,), first=1)])
    _save(conn, [_spread((2,), first=4)])
    layout = load_layout(conn, "r")
    assert len(layout["spreads"]) == 1
    assert layout["spreads"][0]["story_ids"] == [2]
    assert conn.execute("SELECT COUNT(*) FROM layouts").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM layout_spreads").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM layout_placements").fetchone()[0] == 3


def test_delete_run_cascades(conn: sqlite3.Connection) -> None:
    _save(conn)
    conn.execute("DELETE FROM analysis_runs WHERE id = 'r'")
    for table in ("layouts", "layout_spreads", "layout_placements"):
        assert conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0


def test_stale_after_selection_change(conn: sqlite3.Connection) -> None:
    _save(conn)
    assert load_layout(conn, "r")["stale"] is False
    conn.execute("DELETE FROM photo_selections WHERE run_id = 'r' AND image_id = 10")
    assert load_layout(conn, "r")["stale"] is True


def test_selection_hash_is_order_independent(conn: sqlite3.Connection) -> None:
    first = selection_hash(conn, "r")
    conn.execute("UPDATE photo_selections SET position = 100 - position")
    assert selection_hash(conn, "r") == first
    assert len(first) == 64
    assert selection_hash(conn, "empty") != first


def test_migrate_v10_keeps_rows(tmp_path: Path) -> None:
    database = tmp_path / "old.sqlite3"
    with connect(database) as connection:
        _seed(connection)
    with sqlite3.connect(database) as raw:
        for table in ("layout_placements", "layout_spreads", "layouts", "image_object_scans"):
            raw.execute(f"DROP TABLE {table}")
        raw.execute("PRAGMA user_version = 10")
    with connect(database) as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 11
        assert connection.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 10
        assert connection.execute("SELECT COUNT(*) FROM photo_selections").fetchone()[0] == 10
        assert connection.execute("SELECT COUNT(*) FROM stories").fetchone()[0] == 2
        tables = {
            row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        assert {"layouts", "layout_spreads", "layout_placements", "image_object_scans"} <= tables
