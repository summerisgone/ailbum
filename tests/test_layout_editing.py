from __future__ import annotations

import json
import os
from dataclasses import dataclass
from types import SimpleNamespace

import pytest

from ailbum import database
from ailbum.layout import editing
from ailbum.layout.crop import solve_crop
from ailbum.layout.templates import templates_for
from ailbum.layout.types import Rect, Region

FACE = Region(Rect(0.0, 0.3, 0.1, 0.3), 1.0, True, "face")


@dataclass
class Photo:
    image_id: int
    aspect: float
    unit_key: str
    selected: bool = True
    regions: tuple = ()
    rank: float = 0.5


POOL = [
    Photo(1, 1.5, "image:1"),
    Photo(2, 0.7, "image:2"),
    Photo(3, 1.0, "image:3", regions=(FACE,)),
    Photo(4, 1.4, "image:1", selected=False),  # unselected sibling of 1
    Photo(5, 1.2, "image:5"),
]


def fake_load_layout(connection, run_id):
    layout = connection.execute("SELECT id FROM layouts WHERE run_id = ?", (run_id,)).fetchone()
    if layout is None:
        return None
    spreads = []
    for s in connection.execute(
        "SELECT * FROM layout_spreads WHERE layout_id = ? ORDER BY position", (layout["id"],)
    ):
        cells = []
        for p in connection.execute(
            "SELECT * FROM layout_placements WHERE spread_id = ? ORDER BY cell_index", (s["id"],)
        ):
            cells.append({"index": p["cell_index"], "placement": {
                "image_id": p["image_id"],
                "crop": {"x": p["crop_x"], "y": p["crop_y"], "w": p["crop_w"], "h": p["crop_h"]},
                "fit": p["fit"], "warnings": json.loads(p["warnings_json"]),
                "replaced_image_id": p["replaced_image_id"]}})
        spreads.append({"id": s["id"], "template_id": s["template_id"],
                        "warnings": json.loads(s["warnings_json"]), "cells": cells})
    return {"run_id": run_id, "spreads": spreads}


def fake_best_variants(photos, params, limit=3):
    template = templates_for(params.orientation, len(photos))[0]
    ordered = sorted(photos, key=lambda p: p.image_id)
    placements = []
    for cell, photo in zip(template.cells, ordered):
        crop = solve_crop(photo.aspect, photo.regions, cell)
        placements.append(SimpleNamespace(
            cell_index=cell.index, image_id=photo.image_id, crop=crop.rect, fit=crop.fit,
            warnings=crop.violations, replaced_image_id=None))
    draft = SimpleNamespace(template_id=template.id, placements=placements, warnings=["draft"])
    return [draft]


@pytest.fixture
def api(monkeypatch):
    calls = []
    if os.environ.get("SUPERLITE_REAL") != "1":
        def pool(connection, run_id, detector, progress=None):
            calls.append(detector)
            return list(POOL)

        monkeypatch.setattr(editing, "load_pool", pool)
        monkeypatch.setattr(editing, "best_variants", fake_best_variants)
        monkeypatch.setattr(editing, "load_layout", fake_load_layout)
    return SimpleNamespace(detectors=calls)


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "a.db"
    with database.connect(path) as c:
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r','s','o','t','t','b','{}','{}','completed')")
        for i in range(1, 6):
            c.execute(
                "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
                " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,"
                " indexed_at) VALUES (?, ?, 's', ?, ?, 'jpg', 1, 't', 'x', '{}', '{}', 't')",
                (i, f"/p{i}.jpg", f"p{i}", f"p{i}"),
            )
        c.execute("INSERT INTO layouts (id, run_id, orientation, spread_count, min_photos,"
                  " max_photos, selection_hash, created_at, updated_at)"
                  " VALUES (1,'r','vertical',1,3,3,'h','t','t')")
        c.execute("INSERT INTO layout_spreads VALUES (5, 1, 1, 'page_2h', '[1]', '[\"x\"]', 'why')")
        cells = {c.index: c for c in templates_for("vertical", 3)[0].cells}
        for index, image_id in enumerate((1, 2, 3)):
            photo = POOL[image_id - 1]
            r = solve_crop(photo.aspect, photo.regions, cells[index])
            c.execute(
                "INSERT INTO layout_placements VALUES (5, ?, ?, ?, ?, ?, ?, ?, '[]', NULL)",
                (index, image_id, r.rect.x, r.rect.y, r.rect.w, r.rect.h, r.fit))
    return path


def cell(template_id, index):
    template = next(t for t in templates_for("vertical") if t.id == template_id)
    return template.cells[index]


def images(layout):
    return [c["placement"]["image_id"] for c in layout["spreads"][0]["cells"]]


def test_unknown_spread_raises(db, api):
    calls = [
        lambda: editing.alternatives(db, 99, 0),
        lambda: editing.set_photo(db, 99, 0, 1),
        lambda: editing.swap_cells(db, 99, 0, 1),
        lambda: editing.set_template(db, 99, "pages"),
        lambda: editing.set_crop(db, 99, 0, {"x": 0, "y": 0, "w": 1, "h": 1}),
        lambda: editing.recompose_spread(db, 99),
    ]
    for call in calls:
        with pytest.raises(ValueError):
            call()
    with pytest.raises(ValueError):
        editing.set_photo(db, 5, 7, 1)


def test_set_photo_used_elsewhere_swaps(db, api):
    layout = editing.set_photo(db, 5, 0, 2)
    assert images(layout) == [2, 1, 3]
    placement = layout["spreads"][0]["cells"][0]["placement"]
    expected = solve_crop(0.7, (), cell("page_2h", 0))
    assert placement["crop"]["x"] == pytest.approx(expected.rect.x)
    assert placement["fit"] == pytest.approx(expected.fit)
    moved = layout["spreads"][0]["cells"][1]["placement"]
    assert moved["fit"] == pytest.approx(solve_crop(1.5, (), cell("page_2h", 1)).fit)


def test_set_photo_free_image_records_replaced(db, api):
    layout = editing.set_photo(db, 5, 0, 4)
    placement = layout["spreads"][0]["cells"][0]["placement"]
    assert images(layout) == [4, 2, 3]
    assert placement["replaced_image_id"] == 1


def test_set_photo_unknown_image_raises(db, api):
    with pytest.raises(ValueError):
        editing.set_photo(db, 5, 0, 404)


def test_set_template_other_count_rejected(db, api):
    with pytest.raises(ValueError):
        editing.set_template(db, 5, "grid_2x2")
    with pytest.raises(ValueError):
        editing.set_template(db, 5, "nope")
    assert sorted(images(editing.set_template(db, 5, "page_2h"))) == [1, 2, 3]


def test_set_template_same_count_changes_template(db, api):
    layout = editing.set_template(db, 5, "page_2h_m")
    assert layout["spreads"][0]["template_id"] == "page_2h_m"
    assert sorted(images(layout)) == [1, 2, 3]
    for c in layout["spreads"][0]["cells"]:
        photo = POOL[c["placement"]["image_id"] - 1]
        expected = solve_crop(photo.aspect, photo.regions, cell("page_2h_m", c["index"]))
        assert c["placement"]["fit"] == pytest.approx(expected.fit)


def aspect_crop(photo_aspect, index, scale=1.0):
    c = cell("page_2h", index).rect
    ratio = c.w / c.h
    if ratio / photo_aspect <= 1:
        return {"x": 0.0, "y": 0.0, "w": ratio / photo_aspect * scale, "h": scale}
    return {"x": 0.0, "y": 0.0, "w": scale, "h": photo_aspect / ratio * scale}


def test_crop_wrong_aspect_rejected(db, api):
    crop = aspect_crop(0.7, 1)
    crop["w"] *= 1.05
    with pytest.raises(ValueError):
        editing.set_crop(db, 5, 1, crop)
    crop["w"] /= 1.05 * 1.005
    assert editing.set_crop(db, 5, 1, crop)


def test_crop_out_of_range_rejected(db, api):
    with pytest.raises(ValueError):
        editing.set_crop(db, 5, 0, {"x": 2, "y": 0, "w": 1, "h": 1})
    crop = aspect_crop(0.7, 1, 0.5)
    for bad in ({**crop, "x": 0.9}, {**crop, "y": -0.1}, {**crop, "w": 0, "h": 0}):
        with pytest.raises(ValueError):
            editing.set_crop(db, 5, 1, bad)
    for bad in (float("nan"), float("inf"), "a", None):
        with pytest.raises(ValueError):
            editing.set_crop(db, 5, 1, {**crop, "x": bad})
    with pytest.raises(ValueError):
        editing.set_crop(db, 5, 1, {"x": 0})


def test_crop_edge_float_noise_accepted(db, api):
    crop = aspect_crop(0.7, 1)
    crop["x"] = 1.0 - crop["w"] + 1e-12
    layout = editing.set_crop(db, 5, 1, crop)
    assert layout["spreads"][0]["cells"][1]["placement"]["crop"]["x"] == pytest.approx(crop["x"])


def test_set_crop_cutting_face_warns_not_rejects(db, api):
    crop = aspect_crop(1.0, 2, 0.5)
    crop["x"] = 0.5
    layout = editing.set_crop(db, 5, 2, crop)
    placement = layout["spreads"][0]["cells"][2]["placement"]
    assert "face_cut" in placement["warnings"]
    assert placement["crop"]["x"] == 0.5


def test_alternatives_sorted_by_fit_and_capped_24(db, api, monkeypatch):
    many = [Photo(100 + i, 0.5 + i * 0.05, f"image:{100 + i}", selected=i % 2 == 0)
            for i in range(30)]
    if os.environ.get("SUPERLITE_REAL") != "1":
        monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: POOL + many)
    result = editing.alternatives(db, 5, 0)
    assert len(result) == 24
    fits = [a["fit"] for a in result]
    assert fits == sorted(fits, reverse=True)
    assert set(result[0]) == {"image_id", "fit", "warnings", "in_selection"}
    by_id = {a["image_id"]: a for a in result}
    if 100 in by_id:
        assert by_id[100]["in_selection"] is True


def test_alternatives_ties_break_by_image_id(db, api, monkeypatch):
    twins = [Photo(i, 1.0, f"image:{i}") for i in (9, 7, 8)]
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: twins)
    assert [a["image_id"] for a in editing.alternatives(db, 5, 0)] == [7, 8, 9]


def test_swap_recomputes_both_crops(db, api):
    layout = editing.swap_cells(db, 5, 0, 1)
    assert images(layout) == [2, 1, 3]
    cells = layout["spreads"][0]["cells"]
    assert cells[0]["placement"]["fit"] == pytest.approx(
        solve_crop(0.7, (), cell("page_2h", 0)).fit)
    assert cells[1]["placement"]["fit"] == pytest.approx(
        solve_crop(1.5, (), cell("page_2h", 1)).fit)
    assert images(editing.swap_cells(db, 5, 0, 0)) == [2, 1, 3]
    with pytest.raises(ValueError):
        editing.swap_cells(db, 5, 0, 9)


def test_recompose_keeps_same_photos(db, api):
    editing.swap_cells(db, 5, 0, 2)
    layout = editing.recompose_spread(db, 5)
    spread = layout["spreads"][0]
    assert sorted(images(layout)) == [1, 2, 3]
    assert spread["template_id"] == "page_2h"
    assert spread["warnings"] == ["draft"]


def test_edits_keep_detector_scan(db, api):
    editing.alternatives(db, 5, 0)
    editing.set_photo(db, 5, 0, 5)
    editing.recompose_spread(db, 5)
    if api.detectors:
        assert all(d is None for d in api.detectors)
