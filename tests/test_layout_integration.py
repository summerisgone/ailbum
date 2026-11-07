from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Any

import pytest
from PIL import Image

from ailbum import desktop_bridge
from ailbum.database import connect, save_analysis
from ailbum.layout import assistant as assistant_module
from ailbum.layout import service
from ailbum.layout.facts import load_pool
from ailbum.layout.types import LayoutParams
from ailbum.metadata import collect_image_metadata
from ailbum.models import FaceRecord, PhotoRecord, StoryRecord

RUN = "r"
ALBUM = 1
YOLOX = Path(
    os.environ.get(
        "AILBUM_TEST_YOLOX",
        "/private/tmp/claude-501/-Users-ivan-projects-ailbum--claude-worktrees-"
        "photo-layout-grouping-797001/c28d3a48-5363-4e4c-af2b-931b56008da1/"
        "scratchpad/yolox/yolox.onnx",
    )
)
UNSELECTED = {2, 10}  # siblings in the similar clusters 10 and 11
CLUSTERS = {1: 10, 2: 10, 9: 11, 10: 11}
# Face boxes as fractions (x, y, w, h); image 1 has a face on the spine line.
FACES = {
    1: [(0.45, 0.30, 0.10, 0.18)],
    3: [(0.05, 0.40, 0.10, 0.16)],
    4: [(0.82, 0.20, 0.10, 0.16)],
    5: [(0.40, 0.55, 0.12, 0.18), (0.60, 0.50, 0.12, 0.18)],
    9: [(0.42, 0.25, 0.14, 0.12)],
    11: [(0.70, 0.60, 0.10, 0.15)],
    12: [(0.10, 0.10, 0.10, 0.16)],
    14: [(0.48, 0.40, 0.10, 0.15)],
}


def build_library(root: Path) -> Path:
    source = root / "photos"
    source.mkdir()
    records, metadata = [], []
    for n in range(1, 17):
        size = (600, 400) if n % 3 else (400, 600)
        path = source / f"{n}.jpg"
        Image.new("RGB", size, (n * 13 % 255, 90, 140)).save(path, quality=90)
        story = 1 if n <= 8 else 2
        faces = [
            FaceRecord(
                f"f{n}_{i}",
                (round(x * size[0]), round(y * size[1]), round(w * size[0]), round(h * size[1])),
                0.9,
            )
            for i, (x, y, w, h) in enumerate(FACES.get(n, []))
        ]
        records.append(
            PhotoRecord(
                f"p{n}", str(path.resolve()), size[0], size[1],
                f"2024-01-0{story}T10:{n:02d}:00", 100.0, 1.0, 0.8, False,
                similar_cluster=CLUSTERS.get(n), story_id=story,
                selected=n not in UNSELECTED, faces=faces,
            )
        )
        metadata.append(collect_image_metadata(path, source))
    stories = [
        StoryRecord(
            sid, title, [r.photo_id for r in records if r.story_id == sid],
            f"2024-01-0{sid}T10:00:00", f"2024-01-0{sid}T11:00:00", f"p{sid * 8 - 7}",
        )
        for sid, title in ((1, "Ужин"), (2, "Прогулка"))
    ]
    manifest = {
        "run_id": RUN, "started_at": "t", "generated_at": "t", "face_backend": "x",
        "config": {"lmstudio_url": "http://x/v1", "lmstudio_model": "m1"}, "summary": {},
    }
    database = root / "a.sqlite"
    save_analysis(database, source, root / "o", manifest, records, [], metadata, 0.8, stories)
    with connect(database) as connection:
        connection.execute(
            "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
            " VALUES (1, 'u1', 'А', ?, 't', 't')",
            (RUN,),
        )
        for position, record in enumerate(records, 1):
            if record.selected:
                connection.execute(
                    "INSERT INTO album_photos VALUES (?, ?, ?, 't')",
                    (ALBUM, position, position),
                )
    return database


@pytest.fixture
def db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    def down(*args: Any, **kwargs: Any) -> Any:
        raise OSError("LM Studio is down")

    monkeypatch.setattr(assistant_module, "_request_json", down)
    return build_library(tmp_path)


def params(spreads: int = 4, low: int = 3, high: int = 4) -> LayoutParams:
    return LayoutParams("vertical", spreads, low, high)


def bridge(db: Path, action: str, **payload: Any) -> Any:
    return desktop_bridge._dispatch(db, action, payload)


def placed(layout: dict) -> list[tuple[dict, dict]]:
    return [
        (spread, cell)
        for spread in layout["spreads"]
        for cell in spread["cells"]
        if cell["placement"] is not None
    ]


def image_ids(layout: dict) -> list[int]:
    return [cell["placement"]["image_id"] for _, cell in placed(layout)]


def test_full_flow_on_synthetic_library(db: Path) -> None:
    generated = service.generate(db, ALBUM, params(), None)
    layout = bridge(db, "layout.get", album_id=ALBUM)

    assert layout is not None and layout["id"] == generated["id"]
    assert layout["stale"] is False
    assert len(layout["spreads"]) == 4
    ids = image_ids(layout)
    assert len(ids) == len(set(ids))
    assert layout["assistant_model"] is None
    assert any("AI-редактор" in w for w in layout["warnings"])
    assert any("Модель детектора" in w for w in layout["warnings"])
    assert {s for sp in layout["spreads"] for s in sp["story_ids"]} == {1, 2}
    assert {sp["story_title"] for sp in layout["spreads"]} <= {"Ужин", "Прогулка"}

    spread = layout["spreads"][0]
    spread_id = spread["id"]
    ids_before = {c["index"]: c["placement"]["image_id"] for c in spread["cells"]}

    # swap_cells exchanges two photos
    swapped = bridge(db, "layout.swap_cells", spread_id=spread_id, cell_a=0, cell_b=1)
    after = {c["index"]: c["placement"]["image_id"] for c in swapped["spreads"][0]["cells"]}
    assert (after[0], after[1]) == (ids_before[1], ids_before[0])

    # set_photo with an image used elsewhere swaps; each image stays used once
    other = next(c for c in layout["spreads"][-1]["cells"])["placement"]["image_id"]
    changed = bridge(db, "layout.set_photo", spread_id=spread_id, cell_index=0, image_id=other)
    assert changed["spreads"][0]["cells"][0]["placement"]["image_id"] == other
    changed_ids = image_ids(changed)
    assert len(changed_ids) == len(set(changed_ids)) == len(ids)

    # set_crop keeps the window and returns the contract
    cell = changed["spreads"][0]["cells"][0]
    crop = dict(cell["placement"]["crop"])
    crop["x"] = min(1.0 - crop["w"], crop["x"] + 0.0)
    cropped = bridge(db, "layout.set_crop", spread_id=spread_id, cell_index=0, crop=crop)
    assert cropped["spreads"][0]["cells"][0]["placement"]["crop"]["w"] == pytest.approx(crop["w"])

    # set_template with another photo count is rejected, same count is accepted
    count = len(spread["cells"])
    templates = bridge(db, "layout.templates", orientation="vertical", photo_count=count)
    current = cropped["spreads"][0]["template_id"]
    target = next((t["id"] for t in templates if t["id"] != current), None)
    if target is not None:
        retemplated = bridge(db, "layout.set_template", spread_id=spread_id, template_id=target)
        assert retemplated["spreads"][0]["template_id"] == target
    wrong = bridge(db, "layout.templates", orientation="vertical", photo_count=count + 1)
    with pytest.raises(ValueError):
        bridge(db, "layout.set_template", spread_id=spread_id, template_id=wrong[0]["id"])

    assert bridge(db, "layout.get", album_id=ALBUM)["stale"] is False

    # a selection change marks the layout stale
    with connect(db) as connection:
        connection.execute("DELETE FROM album_photos WHERE album_id = ? AND image_id = 3", (ALBUM,))
    assert bridge(db, "layout.get", album_id=ALBUM)["stale"] is True


@pytest.mark.parametrize("spreads", [2, 3, 4, 5])
def test_spread_count_exact_and_images_unique(db: Path, spreads: int) -> None:
    layout = service.generate(db, ALBUM, params(spreads, 2, 4), None)
    assert len(layout["spreads"]) == spreads
    assert [s["position"] for s in layout["spreads"]] == list(range(1, spreads + 1))
    ids = image_ids(layout)
    unplaced = [item["image_id"] for item in layout["unplaced"]]
    assert len(ids) == len(set(ids))
    assert not set(ids) & set(unplaced)


def test_similar_cluster_uses_one_member(db: Path) -> None:
    layout = service.generate(db, ALBUM, params(4, 3, 4), None)
    ids = set(image_ids(layout)) | {i["image_id"] for i in layout["unplaced"]}
    assert len(ids & {1, 2}) <= 1
    assert len(ids & {9, 10}) <= 1


def test_every_placed_face_uncut_on_synthetic_faces(db: Path) -> None:
    layout = service.generate(db, ALBUM, params(), None)
    with connect(db) as connection:
        pool = {p.image_id: p for p in load_pool(connection, ALBUM, None)}
    checked = 0
    for spread, cell in placed(layout):
        placement = cell["placement"]
        crop = placement["crop"]
        for region in pool[placement["image_id"]].regions:
            if not region.hard:
                continue
            checked += 1
            box = region.bbox
            inside_w = min(box.x + box.w, crop["x"] + crop["w"]) - max(box.x, crop["x"])
            inside_h = min(box.y + box.h, crop["y"] + crop["h"]) - max(box.y, crop["y"])
            cover = max(inside_w, 0) * max(inside_h, 0) / (box.w * box.h)
            assert cover >= 0.98, (spread["id"], cell["index"], placement["image_id"])
        assert "face_cut" not in placement["warnings"]
        assert "face_on_spine" not in placement["warnings"]
    assert checked > 0


def test_generation_is_deterministic(db: Path) -> None:
    first = service.generate(db, ALBUM, params(), None)
    second = service.generate(db, ALBUM, params(), None)
    strip = lambda layout: [
        [(c["index"], c["placement"] and c["placement"]["image_id"]) for c in s["cells"]]
        for s in layout["spreads"]
    ]
    assert strip(first) == strip(second)
    assert [s["template_id"] for s in first["spreads"]] == [
        s["template_id"] for s in second["spreads"]
    ]


def test_assistant_reply_is_recorded(db: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def reply(url: str, payload: Any = None, timeout: float = 0) -> dict:
        if url.endswith("/models"):
            return {"data": [{"id": "m1"}]}
        return {"choices": [{"message": {"content": '{"choice":"B","reason":"ритм"}'}}]}

    monkeypatch.setattr(assistant_module, "_request_json", reply)
    layout = service.generate(db, ALBUM, params(), None)
    assert layout["assistant_model"] == "m1"
    ids = image_ids(layout)
    assert len(ids) == len(set(ids))
    assert all(s["assistant_reason"] in (None, "ритм") for s in layout["spreads"])


def test_real_detector_model_when_available(db: Path, tmp_path: Path) -> None:
    if not YOLOX.exists():
        pytest.skip("YOLOX model file is not available")
    from ailbum.cv.objects import OBJECTS_FILENAME

    models = tmp_path / "models"
    models.mkdir()
    shutil.copy(YOLOX, models / OBJECTS_FILENAME)
    layout = service.generate(db, ALBUM, params(), models)
    assert not any("Модель детектора" in w for w in layout["warnings"])
    assert len(layout["spreads"]) == 4
    with connect(db) as connection:
        scans = connection.execute("SELECT COUNT(*) FROM image_object_scans").fetchone()[0]
    assert scans > 0
    assert json.dumps(layout)
