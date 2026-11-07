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
    story_id: int | None = None
    taken_at: str | None = None


POOL = [
    Photo(1, 1.5, "image:1"),
    Photo(2, 0.7, "image:2"),
    Photo(3, 1.0, "image:3", regions=(FACE,)),
    Photo(4, 1.4, "image:1", selected=False),  # unselected sibling of 1
    Photo(5, 1.2, "image:5"),
]


def fake_load_layout(connection, album_id):
    layout = connection.execute("SELECT id FROM layouts WHERE album_id = ?", (album_id,)).fetchone()
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
    return {"album_id": album_id, "spreads": spreads}


def fake_best_variants(photos, params, limit=3):
    template = templates_for(params.orientation, len(photos))[0]
    ordered = sorted(photos, key=lambda p: p.image_id)
    placements = []
    for cell, photo in zip(template.cells, ordered):
        crop = solve_crop(photo.aspect, photo.regions, cell)
        placements.append(SimpleNamespace(
            cell_index=cell.index, image_id=photo.image_id, crop=crop.rect, fit=crop.fit,
            warnings=crop.violations, replaced_image_id=None))
    draft = SimpleNamespace(
        template_id=template.id, placements=placements, warnings=["draft"], score=0.0)
    return [draft]


@pytest.fixture
def api(monkeypatch):
    calls = []
    if os.environ.get("SUPERLITE_REAL") != "1":
        def pool(connection, album_id, detector, progress=None):
            calls.append(detector)
            return list(POOL)

        monkeypatch.setattr(editing, "load_pool", pool)
        monkeypatch.setattr(editing, "best_variants", fake_best_variants)
        monkeypatch.setattr(editing, "load_layout", fake_load_layout)
    return SimpleNamespace(detectors=calls)


def seed_photo(c, root, photo):
    """Rows the real load_pool reads, so SUPERLITE_REAL runs see `photo` in the album pool."""
    i = photo.image_id
    height = 1200 if photo.regions else 1000
    width = round(photo.aspect * height)
    source = root / f"p{i}.jpg"
    source.write_bytes(b"jpg")
    c.execute(
        "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
        " file_size_bytes, modified_at, sha256, width, height, exif_json,"
        " container_metadata_json, indexed_at)"
        " VALUES (?, ?, 's', ?, ?, 'jpg', 1, 't', 'x', ?, ?, '{}', '{}', 't')",
        (i, str(source), f"p{i}", f"p{i}", width, height),
    )
    shared = sum(p.unit_key == photo.unit_key for p in POOL) > 1
    cluster = int(photo.unit_key.split(":")[1]) if shared else None
    c.execute(
        "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,"
        " is_blurry, similar_cluster, story_id, selected) VALUES ('r', ?, ?, 1, 1, ?, 0, ?, ?, ?)",
        (i, f"p{i}", photo.rank, cluster, photo.story_id, int(photo.selected)),
    )
    if photo.selected:
        c.execute("INSERT INTO album_photos VALUES (1, ?, ?, 't')", (i, i))
    if photo.regions:
        # build_regions pads this box to FACE: x -0.2w..+1.2w, y -0.35h..+1.15h.
        c.execute(
            "INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
            " bbox_width, bbox_height, confidence) VALUES ('r', ?, ?, 0, 0, 444, 100, 240, 1)",
            (i, f"f{i}"),
        )


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "a.db"
    with database.connect(path) as c:
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r','s','o','t','t','b','{}','{}','completed')")
        c.execute(
            "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
            " VALUES (1, 'u1', 'А', 'r', 't', 't')")
        for photo in POOL:
            seed_photo(c, tmp_path, photo)
        c.execute("INSERT INTO layouts (id, album_id, run_id, orientation, spread_count, min_photos,"
                  " max_photos, selection_hash, created_at, updated_at)"
                  " VALUES (1,1,'r','vertical',1,3,3,'h','t','t')")
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
    many = [Photo(100 + i, 0.5 + i * 0.05, f"image:{100 + i}", selected=True)
            for i in range(30)]
    if os.environ.get("SUPERLITE_REAL") != "1":
        monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: POOL + many)
    else:
        with database.connect(db) as c:
            for photo in many:
                seed_photo(c, db.parent, photo)
    result = editing.alternatives(db, 5, 0)
    assert len(result) == 24
    fits = [a["fit"] for a in result]
    assert fits == sorted(fits, reverse=True)
    assert set(result[0]) == {
        "image_id", "fit", "warnings", "in_selection", "placed", "similar"}
    by_id = {a["image_id"]: a for a in result}
    if 100 in by_id:
        assert by_id[100]["in_selection"] is True


def test_alternatives_ties_break_by_image_id(db, api, monkeypatch):
    twins = [Photo(i, 1.0, f"image:{i}") for i in (9, 7, 8)]
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: twins)
    assert [a["image_id"] for a in editing.alternatives(db, 5, 0)] == [7, 8, 9]


def test_alternatives_limited_to_spread_stories(db, api, monkeypatch):
    pool = [Photo(10, 1.0, "image:10", story_id=1),
            Photo(11, 1.0, "image:11", story_id=2),
            Photo(12, 1.0, "image:12", story_id=None)]
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: pool)
    assert [a["image_id"] for a in editing.alternatives(db, 5, 0)] == [10]


def test_alternatives_selected_ranked_before_equal_sibling(db, api, monkeypatch):
    pool = [Photo(10, 1.0, "image:10", selected=False, story_id=1),
            Photo(11, 1.0, "image:11", selected=True, story_id=1)]
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: pool)
    result = editing.alternatives(db, 5, 0)
    assert [a["image_id"] for a in result] == [11, 10]
    assert result[0]["fit"] == result[1]["fit"]


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
    if os.environ.get("SUPERLITE_REAL") != "1":
        assert spread["template_id"] == "page_2h"
        assert spread["warnings"] == ["draft"]


def test_edits_keep_detector_scan(db, api):
    editing.alternatives(db, 5, 0)
    editing.set_photo(db, 5, 0, 5)
    editing.recompose_spread(db, 5)
    if api.detectors:
        assert all(d is None for d in api.detectors)


STORY_POOL = [
    Photo(1, 1.5, "image:1", story_id=1),
    Photo(2, 0.7, "image:2", story_id=1),
    Photo(3, 1.0, "image:3", regions=(FACE,), story_id=1),
    Photo(4, 1.4, "image:1", selected=False, story_id=1),
    Photo(5, 1.2, "image:5", story_id=1),
]


@pytest.fixture
def story_pool(monkeypatch):
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: list(STORY_POOL))


def unplaced(db):
    with database.connect(db) as c:
        return json.loads(c.execute("SELECT unplaced_json FROM layouts").fetchone()[0])


def test_alternatives_mark_placed_and_similar(db, api):
    by_id = {a["image_id"]: a for a in editing.alternatives(db, 5, 0)}
    assert by_id[2]["placed"] == {"spread_id": 5, "position": 1, "cell_index": 1}
    assert by_id[5]["placed"] is None
    assert by_id[4]["similar"] is True and by_id[5]["similar"] is False


def test_similar_lists_placed_photo_and_siblings(db, api):
    result = editing.similar(db, 5, 0)
    assert [a["image_id"] for a in result] == [1, 4]
    assert result[0]["placed"]["cell_index"] == 0
    assert result[1]["in_selection"] is False


def test_variants_other_templates_and_counts(db, api, story_pool):
    found = editing.variants(db, 5)
    if os.environ.get("SUPERLITE_REAL") == "1":
        sets = [v["image_ids"] for v in found]
        assert [s for i, s in enumerate(sets) if i == 0 or sets[i - 1] != s] == [
            [1, 2, 3], [1, 2, 3, 5], [1, 2]]
        assert all(v["template_id"] != "page_2h" for v in found if v["image_ids"] == [1, 2, 3])
        found = [v for v in found if v["image_ids"] == [1, 2, 3, 5]]
    else:
        assert [v["image_ids"] for v in found] == [[1, 2, 3, 5], [1, 2]]
        assert found[0]["template_id"] == "grid_2x2"
    cell0 = found[0]["cells"][0]
    assert set(cell0) == {"index", "x", "y", "w", "h", "image_id", "crop"}
    assert 0 <= cell0["x"] <= 1 and 0 < cell0["w"] <= 1


def test_apply_variant_changes_count_and_tracks_unplaced(db, api, story_pool):
    layout = editing.apply_variant(db, 5, "grid_2x2", [1, 2, 3, 5])
    assert sorted(images(layout)) == [1, 2, 3, 5]
    layout = editing.apply_variant(db, 5, "pages", [1, 2])
    assert sorted(images(layout)) == [1, 2]
    assert unplaced(db) == [
        {"image_id": 3, "reason": "removed"}, {"image_id": 5, "reason": "removed"}]
    editing.apply_variant(db, 5, "page_2h", [1, 2, 3])
    assert unplaced(db) == [{"image_id": 5, "reason": "removed"}]
    with pytest.raises(ValueError):
        editing.apply_variant(db, 5, "grid_2x2", [1, 2])
    with pytest.raises(ValueError):
        editing.apply_variant(db, 5, "full", [404])


def test_apply_variant_rejects_photo_on_other_spread(db, api, story_pool):
    with database.connect(db) as c:
        c.execute("INSERT INTO layout_spreads VALUES (6, 1, 2, 'full', '[1]', '[]', NULL)")
        c.execute("INSERT INTO layout_placements VALUES (6, 0, 5, 0, 0, 1, 1, 0.5, '[]', NULL)")
    with pytest.raises(ValueError):
        editing.apply_variant(db, 5, "grid_2x2", [1, 2, 3, 5])


def test_recompose_with_wish_repicks_photos(db, api, monkeypatch):
    face_pool = [*STORY_POOL[:4], Photo(5, 1.2, "image:5", regions=(FACE,), story_id=1)]
    monkeypatch.setattr(editing, "load_pool", lambda c, r, d, progress=None: face_pool)
    layout = editing.recompose_spread(db, 5, "больше лиц")
    assert sorted(images(layout)) == [1, 3, 5]
    assert unplaced(db) == [{"image_id": 2, "reason": "removed"}]
    layout = editing.recompose_spread(db, 5, "пейзажи, без людей")
    assert sorted(images(layout)) == [1, 2, 3]
    with pytest.raises(ValueError):
        editing.recompose_spread(db, 5, "что-нибудь красивое")


def test_mutations_on_ordered_album_raise_reads_allowed(db, api):
    with database.connect(db) as c:
        c.execute("UPDATE albums SET status = 'ordered'")
    calls = [
        lambda: editing.set_photo(db, 5, 0, 5),
        lambda: editing.swap_cells(db, 5, 0, 1),
        lambda: editing.set_template(db, 5, "pages"),
        lambda: editing.set_crop(db, 5, 0, {"x": 0, "y": 0, "w": 1, "h": 1}),
        lambda: editing.recompose_spread(db, 5),
        lambda: editing.apply_variant(db, 5, "page_2h", [1, 2, 3]),
    ]
    for call in calls:
        with pytest.raises(ValueError, match="Альбом заказан"):
            call()
    editing.alternatives(db, 5, 0)
    editing.similar(db, 5, 0)
    editing.variants(db, 5)


def test_fixture_seeds_real_pool_like_fake(db):
    # SUPERLITE_REAL runs use the real load_pool, so the db fixture must hold the same pool.
    from ailbum.layout.facts import load_pool

    with database.connect(db) as c:
        real = {p.image_id: p for p in load_pool(c, 1, None)}
    assert sorted(real) == [p.image_id for p in POOL]
    assert real[1].unit_key == real[4].unit_key != real[5].unit_key
    for photo in POOL:
        got = real[photo.image_id]
        assert got.aspect == pytest.approx(photo.aspect)
        assert got.selected is photo.selected
        boxes = [(r.bbox.x, r.bbox.y, r.bbox.w, r.bbox.h, r.kind) for r in got.regions]
        assert boxes == [pytest.approx((r.bbox.x, r.bbox.y, r.bbox.w, r.bbox.h, r.kind))
                         for r in photo.regions]
